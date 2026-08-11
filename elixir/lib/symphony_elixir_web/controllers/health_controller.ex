defmodule SymphonyElixirWeb.HealthController do
  @moduledoc """
  Lightweight process health endpoint.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params), do: text(conn, "ok")
end
