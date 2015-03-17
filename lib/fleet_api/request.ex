defmodule FleetApi.Request do
  defmacro __using__(_) do
    quote do
      @doc """
      Issue a request to the specified url, optionally passing a list of header
      tuples and a body. The method argument specifies the HTTP method in the
      form of an atom, e.g. :get, :post, :delete, etc.
      """
      @spec request(atom, String.t, [tuple], String.t, [integer]) :: {:ok, any} | {:error, any}
      def request(method, url, headers \\ [], body \\ "", expected_status \\ [200]) do
        options = case Application.get_env(:fleet_api, :proxy) do
          nil -> []
          proxy_opts -> [hackney: [proxy: proxy_opts]]
        end

        case HTTPoison.request(method, url, body, headers, options) do
          {:ok, %HTTPoison.Response{status_code: status} = response} when status in [400..599] ->
            if String.length(response.body) != 0 do
              error = response.body
                      |> Poison.decode!
                      |> Error.from_map
              {:error, error}
            else
              {:error, response}
            end
          {:ok, %HTTPoison.Response{status_code: status} = response} ->
            if status in expected_status do
              if String.length(response.body) != 0 do
                {:ok, Poison.decode!(response.body)}
              else
                {:ok, nil}
              end
            else
              {:error, "Expected response status in #{inspect expected_status} but got #{response.status_code}"}
            end
          error -> error
        end
      end
    end
  end
end