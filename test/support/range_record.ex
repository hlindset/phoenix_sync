defmodule Support.Int4Range do
  use Ecto.Type

  def type, do: :int4range

  def cast(%Postgrex.Range{} = range), do: {:ok, range}
  def cast(_), do: :error

  def load(%Postgrex.Range{} = range), do: {:ok, range}
  def load(_), do: :error

  def dump(%Postgrex.Range{} = range), do: {:ok, range}
  def dump(_), do: :error
end

defmodule Support.RangeRecord do
  use Ecto.Schema

  schema "range_records" do
    field :span, Support.Int4Range
  end
end
