defmodule ExplorerWeb.Notifier do
  @moduledoc """
  Responds to events from EventHandler by sending appropriate channel updates to front-end.
  """

  alias Explorer.{Chain, Market, Repo}
  alias Explorer.Chain.Address
  alias Explorer.ExchangeRates.Token
  alias ExplorerWeb.Endpoint

  def handle_event({:chain_event, :blocks, :realtime_index, blocks}) do
    max_numbered_block = Enum.max_by(blocks, & &1.number).number
    Endpoint.broadcast("transactions:confirmations", "update", %{block_number: max_numbered_block})
    Enum.each(blocks, &broadcast_block/1)
  end

  def handle_event({:chain_event, :transactions, :realtime_index, transaction_hashes}) do
    Enum.each(transaction_hashes, &broadcast_transaction/1)
  end

  def handle_event({:chain_event, :balance_updates, :realtime_index, addresses}) do
    Enum.each(addresses, &broadcast_balance/1)
  end

  def handle_event(_) do
  end

  defp broadcast_balance(%Address{hash: address_hash} = address) do
    Endpoint.broadcast("addresses:#{address_hash}", "balance_update", %{
      address: address,
      exchange_rate: Market.get_exchange_rate(Explorer.coin()) || Token.null()
    })
  end

  defp broadcast_block(block) do
    preloaded_block = Repo.preload(block, [:miner, :transactions])
    Endpoint.broadcast("blocks:new_block", "new_block", %{block: preloaded_block})
  end

  defp broadcast_transaction(transaction_hash) do
    {:ok, transaction} =
      Chain.hash_to_transaction(
        transaction_hash,
        necessity_by_association: %{
          block: :required,
          from_address: :optional,
          to_address: :optional
        }
      )

    Endpoint.broadcast("addresses:#{transaction.from_address_hash}", "transaction", %{
      address: transaction.from_address,
      transaction: transaction
    })

    if transaction.to_address_hash && transaction.to_address_hash != transaction.from_address_hash do
      Endpoint.broadcast("addresses:#{transaction.to_address_hash}", "transaction", %{
        address: transaction.to_address,
        transaction: transaction
      })
    end
  end
end
