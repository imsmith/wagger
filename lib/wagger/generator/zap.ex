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

  # Negative path tests must be well-formed HTTP that reach the WAF for
  # evaluation. Paths that the LB's HTTP parser rejects (e.g. URLs with
  # NUL bytes / %00) test the edge, not the WAF — the WAF never sees the
  # request. Such paths belong in a separate edge-sanity bucket, not here.
  @bad_paths [
    {"/nonexistent", "Undeclared path"},
    {"/api/../etc/passwd", "Path traversal attempt"},
    {"//double-slash", "Double slash"}
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

    # Positive job runs first so its stats test sees only its own responses.
    # Negative jobs intentionally produce 403s and would pollute stats.code.403
    # if positioned before the positive job's test fires.
    positive_job = render_positive_job("waf-positive-tests", positive)
    negative_method_job = render_negative_job("waf-negative-method-tests", negative_method)
    negative_path_job = render_negative_job("waf-negative-path-tests", negative_path)

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

  # Negative jobs assert per-request that the WAF blocks with 403. A WAF
  # block is specifically a 4xx response from the WAF (AWS WAFv2's default
  # is 403). Anything else — backend response, redirect, edge LB reject —
  # means the WAF did not block.
  #
  # ZAP requestor's `responseCode` is integer-equality only. That's fine
  # because we want strict equality on 403: any other response code is by
  # definition not a WAF block.
  #
  # Path test cases must be well-formed enough to reach the WAF; see the
  # comment on @bad_paths for why /%00null and similar URLs were removed.
  defp render_negative_job(name, tests) do
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
          "          responseCode: 403\n"
      end)

    """
      - type: requestor
        name: "#{name}"
        requests:
    #{requests}\
    """
  end

  # Positive job: ZAP requestor's `responseCode` is integer-only, no negation,
  # so we cannot per-request assert "not 403". Instead, omit per-request codes
  # and add a job-level stats test asserting zero 403s across the job's requests.
  # `stats.code.403` is the global counter for 403 responses; the test fires at
  # job completion. This relies on the positive job being run before any
  # negative job that intentionally produces 403s.
  defp render_positive_job(name, tests) do
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
          "          method: \"#{test["method"]}\"\n"
      end)

    """
      - type: requestor
        name: "#{name}"
        requests:
    #{requests}    tests:
          - name: "no 403 responses in positive tests"
            type: stats
            statistic: "stats.code.403"
            operator: "=="
            value: 0
            onFail: "error"
    """
  end

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
