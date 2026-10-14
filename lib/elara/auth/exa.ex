defmodule Elara.Auth.Exa do
  @moduledoc "Private Exa credential storage, never command environment or session state."

  def auth_path do
    Application.get_env(:elara, :exa_auth_path) ||
      Path.join([System.user_home!(), ".elara", "exa-auth.json"])
  end

  def save_key(key) when is_binary(key) do
    if valid?(key) do
      path = auth_path()
      dir = Path.dirname(path)
      tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700),
           :ok <- File.write(tmp, JSON.encode!(%{"api_key" => key})),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    else
      {:error, :invalid_key}
    end
  end

  def load_key do
    with {:ok, bytes} <- File.read(auth_path()),
         {:ok, %{"api_key" => key}} <- JSON.decode(bytes),
         true <- valid?(key) do
      {:ok, key}
    else
      _ -> {:error, :not_logged_in}
    end
  end

  defp valid?(key),
    do: is_binary(key) and byte_size(key) in 1..4096 and Regex.match?(~r/\A[!-~]+\z/, key)
end
