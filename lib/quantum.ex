defmodule Quantum do
  @moduledoc """
  Defines a quantum Scheduler.

  When used, the quantum scheduler expects the `:otp_app` as option.
  The `:otp_app` should point to an OTP application that has
  the quantum runner configuration. For example, the quantum scheduler:

      defmodule MyApp.Scheduler do
        use Quantum, otp_app: :my_app
      end

  Could be configured with:

      config :my_app, MyApp.Scheduler,
        jobs: [
          {"@daily", {Backup, :backup, []}},
        ]

  ## Configuration:

    * `:timeout` - Sometimes, you may come across GenServer
      timeout errors esp. when you have too many jobs or high
      load. The default GenServer.call timeout is 5000.

    * `:jobs` - list of cron jobs to execute

    * `:schedule` - Default schedule of new Job

    * `:run_strategy` - Default Run Strategy of new Job

    * `:overlap` - Default overlap of new Job,

    * `:timezone` - Default timezone of new Job

  """

  require Logger

  alias Quantum.{Job, Normalizer, RunStrategy.Random, Storage.Noop}

  @typedoc """
  Quantum Scheduler Implementation
  """
  @type t :: module

  @defaults [
    cron: [],
    timeout: 5_000,
    schedule: nil,
    overlap: true,
    state: :active,
    timezone: :utc,
    run_strategy: {Random, :cluster},
    debug_logging: true,
    storage: Noop
  ]

  @optional_callbacks init: 1

  # Returns the configuration stored in the `:otp_app` environment.
  @doc false
  @callback config(Keyword.t()) :: Keyword.t()

  @doc """
  Starts supervision and return `{:ok, pid}`
  or just `:ok` if nothing needs to be done.

  Returns `{:error, {:already_started, pid}}` if the repo is already
  started or `{:error, term}` in case anything else goes wrong.

  ## Options

  See the configuration in the moduledoc for options.
  """
  @callback start_link(opts :: Keyword.t()) ::
              {:ok, pid}
              | {:error, {:already_started, pid}}
              | {:error, term}

  @doc """
  A callback executed when the quantum starts.

  It takes the quantum configuration that is stored in the application
  environment, and may change it to suit the application business.

  It must return the updated list of configuration
  """
  @callback init(config :: Keyword.t()) :: Keyword.t()

  @doc """
  Shuts down the quantum represented by the given pid.
  """
  @callback stop(server :: GenServer.server(), timeout) :: :ok

  @doc """
  Creates a new Job. The job can be added by calling `add_job/1`.
  """
  @callback new_job(opts :: Keyword.t()) :: Quantum.Job.t()

  @doc """
  Adds a new job
  """
  @callback add_job(GenStage.stage(), Quantum.Job.t() | {Crontab.CronExpression.t(), Job.task()}) ::
              :ok

  @doc """
  Deactivates a job by name
  """
  @callback deactivate_job(GenStage.stage(), atom) :: :ok

  @doc """
  Activates a job by name
  """
  @callback activate_job(GenStage.stage(), atom) :: :ok

  @doc """
  Resolves a job by name
  """
  @callback find_job(GenStage.stage(), atom) :: Quantum.Job.t() | nil

  @doc """
  Deletes a job by name
  """
  @callback delete_job(GenStage.stage(), atom) :: :ok

  @doc """
  Deletes all jobs
  """
  @callback delete_all_jobs(GenStage.stage()) :: :ok

  @doc """
  Returns the list of currently defined jobs
  """
  @callback jobs(GenStage.stage()) :: [Quantum.Job.t()]

  @doc false
  # Retrieves only scheduler related configuration.
  def scheduler_config(scheduler, otp_app, custom) do
    @defaults
    |> Keyword.merge(Application.get_env(otp_app, scheduler, []))
    |> Keyword.merge(custom)
    |> Keyword.merge(otp_app: otp_app, scheduler: scheduler)
    |> update_in([:schedule], &Normalizer.normalize_schedule/1)
  end

  defmacro __using__(opts) do
    quote bind_quoted: [behaviour: __MODULE__, opts: opts, moduledoc: @moduledoc] do
      @otp_app Keyword.fetch!(opts, :otp_app)
      @moduledoc moduledoc
                 |> String.replace(~r/MyApp\.Scheduler/, Enum.join(Module.split(__MODULE__), "."))
                 |> String.replace(~r/:my_app/, ":" <> Atom.to_string(@otp_app))

      @behaviour behaviour

      @doc false
      @impl behaviour
      def config(custom \\ []) do
        Quantum.scheduler_config(__MODULE__, @otp_app, custom)
      end

      defp __job_broadcaster__ do
        __job_broadcaster__(
          config() |> Keyword.fetch!(:scheduler) |> Module.concat(JobBroadcaster),
          config()
        )
      end

      defp __job_broadcaster__(job_broadcaster, configuration) do
        GenServer.whereis(job_broadcaster)
      end

      defp __timeout__, do: Keyword.fetch!(config(), :timeout)

      @impl behaviour
      def start_link(opts \\ []) do
        opts = Keyword.put_new(opts, :name, __MODULE__)
        Quantum.Supervisor.start_link(__MODULE__, @otp_app, opts)
      end

      @impl behaviour
      def stop(server \\ __MODULE__, timeout \\ 5000) do
        Supervisor.stop(server, :normal, timeout)
      end

      @impl behaviour
      def add_job(server \\ __job_broadcaster__(), job)

      def add_job(server, %Job{name: name} = job) do
        GenStage.cast(server, {:add, job})
      end

      def add_job(server, {%Crontab.CronExpression{} = schedule, task})
          when is_tuple(task) or is_function(task, 0) do
        job =
          new_job()
          |> Job.set_schedule(schedule)
          |> Job.set_task(task)

        add_job(server, job)
      end

      @impl behaviour
      def new_job(config \\ config()), do: Job.new(config)

      @impl behaviour
      def deactivate_job(server \\ __job_broadcaster__(), name)
          when is_atom(name) or is_reference(name) do
        GenStage.cast(server, {:change_state, name, :inactive})
      end

      @impl behaviour
      def activate_job(server \\ __job_broadcaster__(), name)
          when is_atom(name) or is_reference(name) do
        GenStage.cast(server, {:change_state, name, :active})
      end

      @impl behaviour
      def find_job(server \\ __job_broadcaster__(), name)
          when is_atom(name) or is_reference(name) do
        GenStage.call(server, {:find_job, name}, __timeout__())
      end

      @impl behaviour
      def delete_job(server \\ __job_broadcaster__(), name)
          when is_atom(name) or is_reference(name) do
        GenStage.cast(server, {:delete, name})
      end

      @impl behaviour
      def delete_all_jobs(server \\ __job_broadcaster__()) do
        GenStage.cast(server, :delete_all)
      end

      @impl behaviour
      def jobs(server \\ __job_broadcaster__()) do
        GenStage.call(server, :jobs, __timeout__())
      end

      spec = [
        id: opts[:id] || __MODULE__,
        start: Macro.escape(opts[:start]) || quote(do: {__MODULE__, :start_link, [opts]}),
        restart: opts[:restart] || :permanent,
        type: :worker
      ]

      @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
      def child_spec(opts) do
        %{unquote_splicing(spec)}
      end

      defoverridable child_spec: 1
    end
  end
end
