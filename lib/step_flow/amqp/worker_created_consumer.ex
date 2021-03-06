defmodule StepFlow.Amqp.WorkerCreatedConsumer do
  @moduledoc """
  Consumer of all worker creations.
  """

  require Logger
  alias StepFlow.Amqp.WorkerCreatedConsumer
  alias StepFlow.Jobs.Status
  alias StepFlow.LiveWorkers
  alias StepFlow.Workflows
  alias StepFlow.Workflows.StepManager

  use StepFlow.Amqp.CommonConsumer, %{
    queue: "worker_created",
    exchange: "worker_response",
    prefetch_count: 1,
    consumer: &WorkerCreatedConsumer.consume/4
  }

  @doc """
  Consume worker created message.
  """
  def consume(
        channel,
        tag,
        _redelivered,
        %{
          "direct_messaging_queue_name" => direct_messaging_queue_name
        } = _payload
      ) do
    job =
      StepFlow.Jobs.list_jobs(%{
        "direct_messaging_queue_name" => direct_messaging_queue_name
      })
      |> Map.get(:data)
      |> List.first()

    Logger.debug("Worker Creation job search result: #{inspect(job)}")

    case job do
      nil ->
        Basic.reject(channel, tag, requeue: false)

      _ ->
        job_id = job.id

        case live_worker_update(job_id, direct_messaging_queue_name) do
          :ok ->
            Basic.ack(channel, tag)

          :error ->
            Basic.reject(channel, tag, requeue: true)
        end
    end
  end

  def consume(channel, tag, _redelivered, payload) do
    Logger.error("Worker creation #{inspect(payload)}")
    Basic.reject(channel, tag, requeue: false)
  end

  defp live_worker_update(job_id, direct_messaging_queue_name) do
    live_worker = LiveWorkers.get_by(%{"job_id" => job_id})

    case live_worker do
      nil ->
        :error

      _ ->
        LiveWorkers.update_live_worker(live_worker, %{
          "creation_date" => NaiveDateTime.utc_now()
        })

        Status.set_job_status(job_id, "ready_to_init")
        Workflows.notification_from_job(job_id)
        StepManager.check_step_status(%{job_id: job_id})
        :ok
    end
  end
end
