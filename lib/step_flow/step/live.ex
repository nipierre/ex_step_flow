defmodule StepFlow.Step.Live do
  @moduledoc """
  The Live step context.
  """
  alias StepFlow.Amqp.CommonEmitter
  alias StepFlow.Jobs
  alias StepFlow.Jobs.Status
  alias StepFlow.LiveWorkers
  alias StepFlow.Repo
  alias StepFlow.Step.Launch
  alias StepFlow.Step.LaunchParams

  def create_job_live([source_path | _source_paths], launch_params) do
    message = generate_message_live(source_path, launch_params)

    message =
      Map.put(
        message,
        :type,
        "create"
      )

    message = filter_message(message)

    params =
      StepFlow.Map.get_by_key_or_atom(message, :parameters, []) ++
        [%{id: "action", type: "string", value: "create"}]

    message = StepFlow.Map.replace_by_atom(message, :parameters, params)

    case CommonEmitter.publish_json(
           "job_worker_manager",
           LaunchParams.get_step_id(launch_params),
           message
         ) do
      :ok -> {:ok, "started"}
      _ -> {:error, "unable to publish message"}
    end
  end

  def update_job_live(job_id) do
    job = Repo.preload(Jobs.get_job(job_id), [:status, :updates, :workflow])
    workflow_jobs = Repo.preload(job.workflow, [:jobs]).jobs

    steps = job.workflow.steps

    start_next_job_live(workflow_jobs, steps)
  end

  defp start_next_job_live([], _step_id), do: {:ok, "nothing to do"}

  defp start_next_job_live([job | jobs], steps) do
    job = Repo.preload(Jobs.get_job(job.id), [:status])

    if job.status != [] do
      case Status.get_last_status(job.status).state do
        :ready_to_init -> update_live_worker(steps, job, "initializing")
        :ready_to_start -> update_live_worker(steps, job, "starting")
        :update -> update_live_worker(steps, job, "updating")
        :stopped -> delete_live_worker(steps, job)
        _ -> {:ok, "nothing to do"}
      end
    end

    start_next_job_live(jobs, steps)
  end

  def stop_job(job) do
    Jobs.get_message(job)
    |> Map.put(:type, "stop_process")
    |> publish_message(job.step_id)
  end

  defp update_live_worker(steps, job, status) do
    case generate_message(steps, job) do
      {:ok, message} ->
        {:ok, _} = Status.set_job_status(job.id, status)
        publish_message(message, job.step_id)

      _ ->
        {:ok, "nothing to do"}
    end
  end

  defp delete_live_worker(steps, job) do
    {_, message} = generate_message(steps, job)
    message = filter_message(message)

    params =
      StepFlow.Map.get_by_key_or_atom(message, :parameters, []) ++
        [%{id: "action", type: "string", value: "delete"}]

    message = StepFlow.Map.replace_by_atom(message, :parameters, params)

    case CommonEmitter.publish_json(
           "job_worker_manager",
           job.step_id,
           message
         ) do
      :ok -> {:ok, "deleted"}
      _ -> {:error, "unable to publish message"}
    end
  end

  def generate_message(steps, job) do
    message = Jobs.get_message(job)

    requirements = get_requirements(steps, job.step_id)

    {result, message} =
      if requirements != nil do
        replace_ip_address(message, job.id, requirements)
      else
        live_worker = LiveWorkers.get_by(%{"job_id" => job.id})

        if live_worker.creation_date == nil || live_worker.instance_id == "" do
          {:error, message}
        else
          {:ok, message}
        end
      end

    action =
      job.status
      |> Status.get_last_status()
      |> Status.get_action()

    {result, Map.put(message, :type, action)}
  end

  defp replace_ip_address(message, job_id, requirements) do
    job = Repo.preload(Jobs.get_job(job_id), [:status, :updates, :workflow])
    workflow = Repo.preload(job.workflow, [:jobs])

    job_req =
      Jobs.list_jobs(%{
        "workflow_id" => workflow.id,
        "step_id" => requirements |> List.first()
      })
      |> Map.get(:data)
      |> List.first()

    live_worker = LiveWorkers.get_by(%{"job_id" => job_req.id})
    ips = live_worker.ips
    port = live_worker.ports |> List.last()
    created = live_worker.creation_date

    if created != nil && ips != [] do
      ip = ips |> List.first()

      params =
        StepFlow.Map.get_by_key_or_atom(message, :parameters, [])
        |> Enum.map(fn param ->
          case StepFlow.Map.get_by_key_or_atom(param, :id) do
            "source_paths" ->
              value = ["srt://#{ip}:#{port}"]
              StepFlow.Map.replace_by_string(param, "value", value)

            "source_path" ->
              value = "srt://#{ip}:#{port}"
              StepFlow.Map.replace_by_string(param, "value", value)

            _ ->
              param
          end
        end)

      Jobs.update_job(job, %{parameters: params})

      {:ok, StepFlow.Map.replace_by_atom(message, :parameters, params)}
    else
      {:error, message}
    end
  end

  defp filter_message(message) do
    Map.put(
      message,
      :parameters,
      Enum.filter(message.parameters, fn x ->
        Enum.member?(
          ["step_id", "namespace", "worker", "ports", "direct_messaging_queue_name"],
          StepFlow.Map.get_by_key_or_atom(x, :id)
        )
      end)
    )
  end

  defp publish_message(message, step_id) do
    case CommonEmitter.publish_json(
           "direct_messaging_" <> get_direct_messaging_queue(message),
           step_id,
           message,
           "direct_messaging",
           headers: [{"instance_id", :longstr, get_instance_id(message)}]
         ) do
      :ok ->
        {:ok, "started"}

      _ ->
        {:error, "unable to publish message"}
    end
  end

  defp get_direct_messaging_queue(message) do
    StepFlow.Map.get_by_key_or_atom(message, :parameters)
    |> Enum.filter(fn param ->
      StepFlow.Map.get_by_key_or_atom(param, :id) == "direct_messaging_queue_name"
    end)
    |> List.first()
    |> StepFlow.Map.get_by_key_or_atom(:value)
  end

  defp get_instance_id(message) do
    job_id = StepFlow.Map.get_by_key_or_atom(message, :job_id)
    LiveWorkers.get_by(%{"job_id" => job_id}).instance_id |> String.slice(0..11)
  end

  defp get_requirements(steps, step_id) do
    case steps do
      [] ->
        nil

      _ ->
        Enum.filter(steps, fn step ->
          StepFlow.Map.get_by_key_or_atom(step, :id) == step_id
        end)
        |> List.first()
        |> StepFlow.Map.get_by_key_or_atom(:parent_ids)
    end
  end

  def generate_message_live(
        source_path,
        launch_params
      ) do
    parameters =
      Launch.generate_job_parameters_one_for_one(
        source_path,
        launch_params
      )

    job_params = %{
      name: LaunchParams.get_step_name(launch_params),
      step_id: LaunchParams.get_step_id(launch_params),
      is_live: true,
      workflow_id: launch_params.workflow.id,
      parameters: parameters
    }

    {:ok, job} = Jobs.create_job(job_params)

    Jobs.get_message(job)
  end
end
