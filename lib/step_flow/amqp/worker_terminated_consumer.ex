defmodule StepFlow.Amqp.WorkerTerminatedConsumer do
  @moduledoc """
  Consumer of all worker terminations.
  """

  require Logger
  alias StepFlow.Amqp.WorkerTerminatedConsumer
  alias StepFlow.Workflows

  use StepFlow.Amqp.CommonConsumer, %{
    queue: "worker_terminated",
    exchange: "worker_response",
    prefetch_count: 1,
    consumer: &WorkerTerminatedConsumer.consume/4
  }

  @doc """
  Consume worker terminated message.
  """
  def consume(
        channel,
        tag,
        _redelivered,
        %{
          "job_id" => job_id
        } = _payload
      ) do
    Workflows.notification_from_job(job_id)
    Basic.ack(channel, tag)
  end

  def consume(channel, tag, _redelivered, payload) do
    Logger.error("Worker terminated #{inspect(payload)}")
    Basic.reject(channel, tag, requeue: false)
  end
end
