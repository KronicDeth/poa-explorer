defmodule EthereumJSONRPC do
  @moduledoc """
  Ethereum JSONRPC client.

  ## Configuration

  Configuration for parity URLs can be provided with the following mix config:

      config :ethereum_jsonrpc,
        url: "https://sokol.poa.network",
        trace_url: "https://sokol-trace.poa.network",
        http: [recv_timeout: 60_000, timeout: 60_000, hackney: [pool: :ethereum_jsonrpc]]

  Note: the tracing node URL is provided separately from `:url`, via `:trace_url`. The trace URL and is used for
  `fetch_internal_transactions`, which is only a supported method on tracing nodes. The `:http` option is passed
  directly to the HTTP library (`HTTPoison`), which forwards the options down to `:hackney`.
  """

  alias Explorer.Chain.Block
  alias EthereumJSONRPC.{Blocks, Receipts, Transactions, Transport, Variant}

  @typedoc """
  Truncated 20-byte [KECCAK-256](https://en.wikipedia.org/wiki/SHA-3) hash encoded as a hexadecimal number in a
  `String.t`.
  """
  @type address :: String.t()

  @typedoc """
  Binary data encoded as a single hexadecimal number in a `String.t`
  """
  @type data :: String.t()

  @typedoc """
  A full 32-byte [KECCAK-256](https://en.wikipedia.org/wiki/SHA-3) hash encoded as a hexadecimal number in a `String.t`

  ## Example

     "0xe670ec64341771606e55d6b4ca35a1a6b75ee3d5145a99d05921026d1527331"

  """
  @type hash :: String.t()

  @typedoc """
  Named arguments to `json_rpc/2`.

   * `:transport` - the `t:EthereumJSONRPC.Transport.t/0` callback module
   * `:transport_options` - options passed to `c:EthereumJSONRPC.Transport.json_rpc/2`
   * `:variant` - the `t:EthereumJSONRPC.Variant.t/0` callback module

  """
  @type json_rpc_named_arguments :: [
          {:transport, Transport.t()} | {:transport_options, Transport.options()} | {:variant, Variant.t()}
        ]

  @typedoc """
  8 byte [KECCAK-256](https://en.wikipedia.org/wiki/SHA-3) hash of the proof-of-work.
  """
  @type nonce :: String.t()

  @typedoc """
  A number encoded as a hexadecimal number in a `String.t`

  ## Example

      "0x1b4"

  """
  @type quantity :: String.t()

  @typedoc """
  A logic block tag that can be used in place of a block number.

  | Tag          | Description                    |
  |--------------|--------------------------------|
  | `"earliest"` | The first block in the chain   |
  | `"latest"`   | The latest collated block.     |
  | `"pending"`  | The next block to be collated. |
  """
  @type tag :: String.t()

  @typedoc """
  Unix timestamp encoded as a hexadecimal number in a `String.t`
  """
  @type timestamp :: String.t()

  @typedoc """
  JSONRPC request id can be a `String.t` or Integer
  """
  @type request_id :: String.t() | non_neg_integer()

  @doc """
  Execute smart contract functions.

  Receives a list of smart contract functions to execute. Each function is
  represented by a map. The contract_address key is the address of the smart
  contract being queried, the data key indicates which function should be
  executed, as well as what are their arguments, and the id key is the id that
  is going to be sent with the JSON-RPC call.

  ## Examples

  Execute the "sum" function that receives two arguments (20 and 22) and returns their sum (42):
  iex> EthereumJSONRPC.execute_contract_functions([%{
  ...> contract_address: "0x7e50612682b8ee2a8bb94774d50d6c2955726526",
  ...> data: "0xcad0899b00000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000016",
  ...> id: "sum"
  ...> }])
  {:ok,
    [
      %{
        "id" => "sum",
        "jsonrpc" => "2.0",
        "result" => "0x000000000000000000000000000000000000000000000000000000000000002a"
      }
    ]}
  """
  @spec execute_contract_functions(
          [%{contract_address: String.t(), data: String.t(), id: String.t()}],
          json_rpc_named_arguments
        ) :: {:ok, []}
  def execute_contract_functions(functions, json_rpc_named_arguments) do
    functions
    |> Enum.map(&build_eth_call_payload/1)
    |> json_rpc(json_rpc_named_arguments)
  end

  defp build_eth_call_payload(%{contract_address: address, data: data, id: id}) do
    params = [%{to: address, data: data}]
    request(%{id: id, method: "eth_call", params: params})
  end

  @doc """
  Fetches balance for each address `hash` at the `block_number`
  """
  @spec fetch_balances(
          [%{required(:block_quantity) => quantity, required(:hash_data) => data()}],
          json_rpc_named_arguments
        ) ::
          {:ok,
           [
             %{
               required(:address_hash) => quantity,
               required(:block_number) => Block.block_number(),
               required(:value) => non_neg_integer()
             }
           ]}
          | {:error, reason :: term}
  def fetch_balances(params_list, json_rpc_named_arguments)
      when is_list(params_list) and is_list(json_rpc_named_arguments) do
    id_to_params = id_to_params(params_list)

    with {:ok, responses} <-
           id_to_params
           |> get_balance_requests()
           |> json_rpc(json_rpc_named_arguments) do
      get_balance_responses_to_balances_params(responses, id_to_params)
    end
  end

  @doc """
  Fetches blocks by block hashes.

  Transaction data is included for each block.
  """
  def fetch_blocks_by_hash(block_hashes, json_rpc_named_arguments) do
    block_hashes
    |> get_block_by_hash_requests()
    |> json_rpc(json_rpc_named_arguments)
    |> handle_get_blocks()
    |> case do
      {:ok, _next, results} -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches blocks by block number range.
  """
  def fetch_blocks_by_range(_first.._last = range, json_rpc_named_arguments) do
    range
    |> get_block_by_number_requests()
    |> json_rpc(json_rpc_named_arguments)
    |> handle_get_blocks()
  end

  @doc """
  Fetches block number by `t:tag/0`.

  ## Returns

   * `{:ok, number}` - the block number for the given `tag`.
   * `{:error, :invalid_tag}` - When `tag` is not a valid `t:tag/0`.
   * `{:error, reason}` - other JSONRPC error.

  """
  @spec fetch_block_number_by_tag(tag(), json_rpc_named_arguments) ::
          {:ok, non_neg_integer()} | {:error, reason :: :invalid_tag | term()}
  def fetch_block_number_by_tag(tag, json_rpc_named_arguments) when tag in ~w(earliest latest pending) do
    tag
    |> get_block_by_tag_request()
    |> json_rpc(json_rpc_named_arguments)
    |> handle_get_block_by_tag()
  end

  @doc """
  Fetches internal transactions from variant API.
  """
  def fetch_internal_transactions(params_list, json_rpc_named_arguments) when is_list(params_list) do
    Keyword.fetch!(json_rpc_named_arguments, :variant).fetch_internal_transactions(
      params_list,
      json_rpc_named_arguments
    )
  end

  @doc """
  Fetches pending transactions from variant API.
  """
  def fetch_pending_transactions(json_rpc_named_arguments) do
    Keyword.fetch!(json_rpc_named_arguments, :variant).fetch_pending_transactions(json_rpc_named_arguments)
  end

  @spec fetch_transaction_receipts(
          [
            %{required(:gas) => non_neg_integer(), required(:hash) => hash, optional(atom) => any}
          ],
          json_rpc_named_arguments
        ) :: {:ok, %{logs: list(), receipts: list()}} | {:error, reason :: term}
  def fetch_transaction_receipts(transactions_params, json_rpc_named_arguments) when is_list(transactions_params) do
    Receipts.fetch(transactions_params, json_rpc_named_arguments)
  end

  @doc """
  Assigns an id to each set of params in `params_list` for batch request-response correlation
  """
  def id_to_params(params_list) do
    params_list
    |> Stream.with_index()
    |> Enum.into(%{}, fn {params, id} -> {id, params} end)
  end

  @doc """
    1. POSTs JSON `payload` to `url`
    2. Decodes the response
    3. Handles the response

  ## Returns

    * Handled response
    * `{:error, reason}` if POST failes
  """
  @spec json_rpc(Transport.request(), json_rpc_named_arguments) ::
          {:ok, Transport.result()} | {:error, reason :: term()}
  @spec json_rpc(Transport.batch_request(), json_rpc_named_arguments) ::
          {:ok, Transport.batch_response()} | {:error, reason :: term()}
  def json_rpc(request, named_arguments) when (is_map(request) or is_list(request)) and is_list(named_arguments) do
    transport = Keyword.fetch!(named_arguments, :transport)
    transport_options = Keyword.fetch!(named_arguments, :transport_options)

    transport.json_rpc(request, transport_options)
  end

  @doc """
  Converts `t:nonce/0` to `t:non_neg_integer/0`
  """
  @spec nonce_to_integer(nonce) :: non_neg_integer()
  def nonce_to_integer(nonce) do
    quantity_to_integer(nonce)
  end

  @doc """
  Converts `t:quantity/0` to `t:non_neg_integer/0`.
  """
  @spec quantity_to_integer(quantity) :: non_neg_integer()
  def quantity_to_integer("0x" <> hexadecimal_digits) do
    String.to_integer(hexadecimal_digits, 16)
  end

  @doc """
  Converts `t:non_neg_integer/0` to `t:quantity/0`
  """
  @spec integer_to_quantity(non_neg_integer) :: quantity
  def integer_to_quantity(integer) when is_integer(integer) and integer >= 0 do
    "0x" <> Integer.to_string(integer, 16)
  end

  @doc """
  A request payload for a JSONRPC.
  """
  @spec request(%{id: request_id, method: String.t(), params: list()}) :: Transport.request()
  def request(%{method: method, params: params} = map)
      when is_binary(method) and is_list(params) do
    Map.put(map, :jsonrpc, "2.0")
  end

  @doc """
  Converts `t:timestamp/0` to `t:DateTime.t/0`
  """
  def timestamp_to_datetime(timestamp) do
    timestamp
    |> quantity_to_integer()
    |> Timex.from_unix()
  end

  defp get_balance_requests(id_to_params) when is_map(id_to_params) do
    Enum.map(id_to_params, fn {id, %{block_quantity: block_quantity, hash_data: hash_data}} ->
      get_balance_request(%{id: id, block_quantity: block_quantity, hash_data: hash_data})
    end)
  end

  defp get_balance_request(%{id: id, block_quantity: block_quantity, hash_data: hash_data}) do
    request(%{id: id, method: "eth_getBalance", params: [hash_data, block_quantity]})
  end

  defp get_balance_responses_to_balances_params(responses, id_to_params)
       when is_list(responses) and is_map(id_to_params) do
    {status, reversed} =
      responses
      |> Enum.map(&get_balance_responses_to_balance_params(&1, id_to_params))
      |> Enum.reduce(
        {:ok, []},
        fn
          {:ok, address_params}, {:ok, address_params_list} ->
            {:ok, [address_params | address_params_list]}

          {:ok, _}, {:error, _} = acc_error ->
            acc_error

          {:error, reason}, {:ok, _} ->
            {:error, [reason]}

          {:error, reason}, {:error, acc_reason} ->
            {:error, [reason | acc_reason]}
        end
      )

    {status, Enum.reverse(reversed)}
  end

  defp get_balance_responses_to_balance_params(%{id: id, result: fetched_balance_quantity}, id_to_params)
       when is_map(id_to_params) do
    %{block_quantity: block_quantity, hash_data: hash_data} = Map.fetch!(id_to_params, id)

    {:ok,
     %{
       value: quantity_to_integer(fetched_balance_quantity),
       block_number: quantity_to_integer(block_quantity),
       address_hash: hash_data
     }}
  end

  defp get_balance_responses_to_balance_params(%{id: id, error: error}, id_to_params)
       when is_map(id_to_params) do
    %{block_quantity: block_quantity, hash_data: hash_data} = Map.fetch!(id_to_params, id)

    annotated_error = Map.put(error, :data, %{"blockNumber" => block_quantity, "hash" => hash_data})

    {:error, annotated_error}
  end

  defp get_block_by_hash_requests(block_hashes) do
    for block_hash <- block_hashes do
      get_block_by_hash_request(%{id: block_hash, hash: block_hash, transactions: :full})
    end
  end

  defp get_block_by_hash_request(%{id: id} = options) do
    request(%{id: id, method: "eth_getBlockByHash", params: get_block_by_hash_params(options)})
  end

  defp get_block_by_hash_params(%{hash: hash} = options) do
    [hash, get_block_transactions(options)]
  end

  defp get_block_by_number_requests(range) do
    for current <- range do
      get_block_by_number_request(%{id: current, quantity: current, transactions: :full})
    end
  end

  defp get_block_by_number_request(%{id: id} = options) do
    request(%{id: id, method: "eth_getBlockByNumber", params: get_block_by_number_params(options)})
  end

  defp get_block_by_tag_request(tag) do
    # eth_getBlockByNumber accepts either a number OR a tag
    get_block_by_number_request(%{id: 0, tag: tag, transactions: :hashes})
  end

  defp get_block_by_number_params(options) do
    [get_block_by_number_subject(options), get_block_transactions(options)]
  end

  defp get_block_by_number_subject(options) do
    case {Map.fetch(options, :quantity), Map.fetch(options, :tag)} do
      {{:ok, integer}, :error} when is_integer(integer) ->
        integer_to_quantity(integer)

      {:error, {:ok, tag}} ->
        tag

      {{:ok, _}, {:ok, _}} ->
        raise ArgumentError, "Only one of :quantity or :tag can be passed to get_block_by_number_request"

      {:error, :error} ->
        raise ArgumentError, "One of :quantity or :tag MUST be passed to get_block_by_number_request"
    end
  end

  defp get_block_transactions(%{transactions: transactions}) do
    case transactions do
      :full -> true
      :hashes -> false
    end
  end

  defp handle_get_blocks({:ok, results}) do
    {blocks, next} =
      Enum.reduce(results, {[], :more}, fn
        %{result: nil}, {blocks, _} -> {blocks, :end_of_chain}
        %{result: %{} = block}, {blocks, next} -> {[block | blocks], next}
      end)

    elixir_blocks = Blocks.to_elixir(blocks)
    elixir_transactions = Blocks.elixir_to_transactions(elixir_blocks)
    blocks_params = Blocks.elixir_to_params(elixir_blocks)
    transactions_params = Transactions.elixir_to_params(elixir_transactions)

    {:ok, next,
     %{
       blocks: blocks_params,
       transactions: transactions_params
     }}
  end

  defp handle_get_blocks({:error, _} = error), do: error

  defp handle_get_block_by_tag({:ok, %{"number" => quantity}}) do
    {:ok, quantity_to_integer(quantity)}
  end

  defp handle_get_block_by_tag({:error, %{"code" => -32602}}), do: {:error, :invalid_tag}
  defp handle_get_block_by_tag({:error, _} = error), do: error
end
