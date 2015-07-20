defmodule FleetApi.Etcd do
  @moduledoc """
  Accesses the Fleet API via a URL discovered through etcd.  
  """
  require Logger
  use FleetApi
  use GenServer

  @port_regex ~r/(:\d+)/

  ## GenServer initialization
  def start_link(etcd_token) do
    GenServer.start_link(__MODULE__, etcd_token)
  end

  def init(etcd_token) do
    {:ok, %{etcd_token: etcd_token, last_updated: nil, nodes: []}}
  end

  @doc """
  Retrieves a Fleet node URL based on the information stored in etcd, using the
  etcd token specified when the GenServer was started.
  """
  @spec get_node_url(pid) :: String.t | {:error, any}
  def get_node_url(pid) do
    case GenServer.call(pid, :get_node_url, 60_000) do
      {:ok, node_url} -> 
        node_url
        |> fix_etcd_node_url

      error -> error
    end
  end

  defp fix_etcd_node_url(node_url) do
    config = Application.get_env(:fleet_api, :etcd)
    if config[:fix_port_number] do
      Regex.replace(@port_regex, node_url, ":#{config[:api_port]}", global: false)
    else
      node_url
    end
  end

  def handle_call(:get_node_url, _from, state) do
    case get_state(state) do
      {:ok, state} ->
        case get_valid_node(state.nodes) do
          {nil, nodes} ->
            Logger.error "[FleetApi] Node list contained no valid nodes!"
            {:reply, {:error, :no_valid_nodes}, Map.put(state, :nodes, nodes)}
          {node_url, nodes} ->
            Logger.debug "[FleetApi] Confirmed node #{inspect node_url} was valid."
            {:reply, {:ok, node_url}, Map.put(state, :nodes, nodes)}
        end
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # validates the provided state is relevant, and if not, attempts to retrieve
  # new state data from etcd.io up to 5 times before failing.
  @spec get_state(Map.t, integer) :: {:ok, Map.t} | {:error, any}
  defp get_state(state, attempts \\ 0) do
    if valid_state?(state) do
      {:ok, state}
    else
      Logger.debug "[FleetApi] Refreshing list of etcd nodes, attempt: #{attempts}."
      case refresh_nodes(state.etcd_token) do
        {:ok, nodes} ->
          node_maps = for node_url <- nodes, do: %{ url: node_url, is_valid: nil }
          Logger.debug "[FleetApi] Successfully retrieved list of #{length nodes} etcd nodes."
          {:ok, %{state | nodes: node_maps, last_updated: :os.timestamp}}
        {:error, reason} ->
          if attempts < 5 do
            get_state(state, attempts + 1)
          else
            Logger.error "[FleetApi] Couldn't refresh list of etcd nodes after 5 attempts. Failing."
            {:error, reason}
          end
      end
    end
  end

  @spec refresh_nodes(String.t) :: [String.t]
  defp refresh_nodes(etcd_token) do
    Logger.debug "[FleetApi] Refreshing nodes for etcd token: #{etcd_token}"
    try do
      case request(:get, "https://discovery.etcd.io/#{etcd_token}", [{"Accept", "application/json"}]) do
        {:ok, %{"node" => node}} ->
          nodes = for n <- node["nodes"] || [], do: n["value"]
          {:ok, nodes}
        {:error, error} ->
          Logger.error "[FleetApi] An error occurred refreshing the list of etcd nodes: #{inspect error}."
          {:error, error.reason}
      end
    rescue e ->
      Logger.error "[FleetApi] An exception was raised during the request to etcd: #{inspect e}"
      Logger.debug "[FleetApi] Issuing a request to google just to check httpoison..."
      test_httpoison_request()

      {:error, e}
    catch e ->
      Logger.error "[FleetApi] refresh_node request threw: #{inspect e}."
      {:error, e}
    end
  end

  defp test_httpoison_request() do
    try do
      case request(:get, "https://google.com", [], "", 200..399, false) do
        {:ok, result} ->
          Logger.debug "[FleetApi] google.com request succeeded: #{inspect result}"
        {:error, error} ->
          Logger.warn "[FleetApi] google.com request failed: #{inspect error}"
      end
    rescue e ->
      Logger.warn "[FleetApi] google.com request raised an exception: #{inspect e}"
    catch e ->
      Logger.error "[FleetApi] google.com request threw: #{inspect e}."
    end
  end

  # finds the first node for which the discovery endpoint returns data.
  @spec get_valid_node([Map.t]) :: {String.t | nil, [Map.t]}
  defp get_valid_node(nodes) do
    Logger.debug "[FleetApi] Finding a valid node..."
    filtered = Enum.filter(nodes, fn node -> node.is_valid != false end)
    get_valid_node(nodes, filtered)
  end

  @spec get_valid_node([Map.t], [Map.t]) :: {String.t | nil, [Map.t]}
  defp get_valid_node(nodes, candidates) when length(candidates) > 0 do
    # Seed the RNG
    :random.seed(:os.timestamp)
    node = candidates
            |> Enum.shuffle
            |> List.first

    if node.is_valid == true do
      {node.url, nodes}
    else
      is_valid = validate_node(node.url)

      # Update our nodes list now that we know if this node is valid or not
      index = Enum.find_index(nodes, fn n -> n.url == node.url end)
      node = Map.put(node, :is_valid, is_valid)
      nodes = List.replace_at(nodes, index, node)

      if is_valid do
        {node.url, nodes}
      else
        # Since this node isn't valid, recurse back into get_valid_nodes to try
        # to find a valid node.
        get_valid_node(nodes)
      end
    end
  end

  defp get_valid_node(nodes, candidates) when length(candidates) == 0 do
    Logger.warn "[FleetApi] All nodes have been checked, and no valid nodes were found."
    {nil, nodes}
  end

  defp validate_node(node_url) do
    node_url
    |> fix_etcd_node_url
    |> api_discovery
    |> case do
      {:ok, _discovery} -> true
      _ -> false
    end
  end

  @spec valid_state?(Map.t) :: boolean
  defp valid_state?(state) do
    valid_token = state.etcd_token != nil && String.length(String.strip(state.etcd_token)) > 0

    # Check that we've refreshed in the last 10 minutes
    valid_time = state.last_updated != nil && :timer.now_diff(:os.timestamp, state.last_updated) < 600_000_000

    valid_nodes = state.nodes != nil && length(state.nodes) > 0

    valid_token && valid_time && valid_nodes
  end
end