defmodule Wagger.Generator.Zap do
  @moduledoc """
  OWASP ZAP automation framework test plan generator implementing the `Wagger.Generator` behaviour.

  Produces a ZAP automation plan YAML file with three requestor jobs:
  - Positive tests: each declared route + method should return non-403
  - Negative method tests: disallowed methods on declared routes should return 403
  - Negative path tests: synthetic undeclared paths should return 403
  """

  @behaviour Wagger.Generator

  @all_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @default_target_url "{{TARGET_URL}}"

  @bad_paths [
    {"/nonexistent", "Undeclared path"},
    {"/api/../etc/passwd", "Path traversal attempt"},
    {"//double-slash", "Double slash"},
    {"/%00null", "Null byte injection"}
  ]

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-zap.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    target_url = config[:target_url] || config["target_url"] || @default_target_url
    config_name = config[:prefix] || config["prefix"] || "zap"

    # Strip trailing slash from target URL
    target_url = String.trim_trailing(target_url, "/")

    normalized = Enum.map(routes, &normalize/1)

    positive = build_positive_tests(normalized, target_url)
    negative_method = build_negative_method_tests(normalized, target_url)
    negative_path = build_negative_path_tests(target_url)

    %{
      "zap-config" => %{
        "config-name" => config_name,
        "target-url" => target_url,
        "generated-at" => iso8601_now(),
        "positive-tests" => positive,
        "negative-method-tests" => negative_method,
        "negative-path-tests" => negative_path
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["zap-config"]
    config_name = cfg["config-name"]
    target_url = cfg["target-url"]
    generated_at = cfg["generated-at"]
    positive = cfg["positive-tests"]
    negative_method = cfg["negative-method-tests"]
    negative_path = cfg["negative-path-tests"]

    header = """
    # ZAP automation plan for #{config_name}
    # Generated #{generated_at}
    ---
    env:
      contexts:
        - name: "#{config_name}-waf-verify"
          urls:
            - "#{target_url}"
    """

    positive_job = render_job("waf-positive-tests", positive, "!403")
    negative_method_job = render_job("waf-negative-method-tests", negative_method, "403")
    negative_path_job = render_job("waf-negative-path-tests", negative_path, "403")

    (header <> "\njobs:\n" <> positive_job <> "\n" <> negative_method_job <> "\n" <> negative_path_job)
    |> String.trim_trailing()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize(route) do
    %{
      path: route[:path] || route["path"],
      path_type: route[:path_type] || route["path_type"],
      methods: route[:methods] || route["methods"],
      description: route[:description] || route["description"]
    }
  end

  defp build_positive_tests(routes, target_url) do
    Enum.flat_map(routes, fn route ->
      test_path = expand_params(route.path)
      desc_base = route.description || route.path

      Enum.map(route.methods, fn method ->
        %{
          "url" => target_url <> test_path,
          "method" => method,
          "description" => "#{method} #{route.path} should be allowed — #{desc_base}"
        }
      end)
    end)
  end

  defp build_negative_method_tests(routes, target_url) do
    Enum.flat_map(routes, fn route ->
      test_path = expand_params(route.path)
      disallowed = @all_methods -- route.methods
      desc_base = route.description || route.path

      Enum.map(disallowed, fn method ->
        %{
          "url" => target_url <> test_path,
          "method" => method,
          "description" => "#{method} #{route.path} should be blocked — #{desc_base}"
        }
      end)
    end)
  end

  defp build_negative_path_tests(target_url) do
    Enum.map(@bad_paths, fn {path, desc} ->
      %{
        "url" => target_url <> path,
        "method" => "GET",
        "description" => "#{desc}"
      }
    end)
  end

  defp expand_params(path) do
    String.replace(path, ~r/\{[^}]+\}/, "1")
  end

  defp render_job(name, tests, expected_code) do
    requests =
      Enum.map_join(tests, "", fn test ->
        desc_line =
          if test["description"] do
            "        # #{test["description"]}\n"
          else
            ""
          end

        desc_line <>
          "        - url: \"#{test["url"]}\"\n" <>
          "          method: \"#{test["method"]}\"\n" <>
          "          responseCode: \"#{expected_code}\"\n"
      end)

    """
      - type: requestor
        name: "#{name}"
        requests:
    #{requests}\
    """
  end

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
