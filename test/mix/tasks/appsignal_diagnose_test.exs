defmodule Mix.Tasks.Appsignal.DiagnoseTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  import AppsignalTest.Utils

  @system Application.get_env(:appsignal, :appsignal_system, Appsignal.System)
  @nif Application.get_env(:appsignal, :appsignal_nif, Appsignal.Nif)
  @diagnose_report Application.get_env(:appsignal, :appsignal_diagnose_report, Appsignal.Diagnose.Report)
  @appsignal_version Mix.Project.config[:version]
  @agent_version Appsignal.Agent.version

  defp run, do: capture_io("Y", &run_fn/0)
  defp run(input), do: capture_io(input, &run_fn/0)
  defp run_fn, do: Mix.Tasks.Appsignal.Diagnose.run(nil)

  setup do
    @diagnose_report.start_link
    @system.start_link
    @nif.start_link
    # By default use the same as the actual state of the Nif
    @nif.set(:loaded?, Appsignal.Nif.loaded?)

    # By default, Push API key is valid
    auth_bypass = Bypass.open
    setup_with_config(%{endpoint: "http://localhost:#{auth_bypass.port}"})
    Bypass.expect auth_bypass, fn conn ->
      assert "/1/auth" == conn.request_path
      assert "GET" == conn.method
      Plug.Conn.resp(conn, 200, "")
    end

    {:ok, %{auth_bypass: auth_bypass}}
  end

  defp received_report do
    @diagnose_report.get(:sent_report)
  end

  test "outputs AppSignal support header" do
    output = run()
    assert String.contains? output, "AppSignal diagnose"
    assert String.contains? output, "http://docs.appsignal.com/"
    assert String.contains? output, "support@appsignal.com"
  end

  test "outputs library information" do
    output = run()
    assert String.contains? output, "AppSignal agent"
    assert String.contains? output, "Language: Elixir"
    assert String.contains? output, "Package version: #{@appsignal_version}"
    assert String.contains? output, "Agent version: #{@agent_version}"
  end

  test "adds library information to report" do
    run()
    report = received_report()
    assert report[:library] == %{
      agent_version: @agent_version,
      extension_loaded: Appsignal.Nif.loaded?,
      language: "elixir",
      package_version: @appsignal_version
    }
  end

  test "adds process information to report" do
    run()
    report = received_report()
    assert report[:process] == %{uid: @system.uid}
  end

  @tag :skip_env_test_no_nif
  describe "when Nif is loaded" do
    setup do: @nif.set(:loaded?, true)

    test "outputs that the Nif is loaded" do
      output = run()
      assert String.contains? output, "Nif loaded: yes"
    end

    test "adds library extension_loaded true to report" do
      run()
      report = received_report()
      assert report[:library][:extension_loaded] == true
    end
  end

  describe "when Nif is not loaded" do
    setup do: @nif.set(:loaded?, false)

    test "outputs that the Nif is not loaded" do
      output = run()
      assert String.contains? output, "Nif loaded: no"
    end

    test "adds library extension_loaded false to report" do
      run()
      report = received_report()
      assert report[:library][:extension_loaded] == false
    end
  end

  test "outputs host information" do
    output = run()
    assert String.contains? output, "Host information"
    assert String.contains? output, "Architecture: #{:erlang.system_info(:system_architecture)}"
    assert String.contains? output, "Elixir version: #{System.version}"
    assert String.contains? output, "OTP version: #{System.otp_release}"
  end

  test "adds host information to report" do
    run()
    report =
      received_report()[:host]
      |> Map.drop([:root, :running_in_container])
    assert report == %{
      architecture: to_string(:erlang.system_info(:system_architecture)),
      language_version: System.version,
      otp_version: System.otp_release,
      heroku: false
    }
  end

  describe "when on Heroku" do
    setup do: @system.set(:heroku, true)

    test "outputs Heroku: yes" do
      output = run()
      assert String.contains? output, "Heroku: yes"
    end

    test "adds host heroku true to report" do
      run()
      report = received_report()
      assert report[:host][:heroku] == true
    end
  end

  describe "when running in a container" do
    setup do: @nif.set(:running_in_container?, true)

    test "outputs Container: yes" do
      output = run()
      assert String.contains? output, "Container: yes"
    end

    test "adds host running_in_container true to report" do
      run()
      report = received_report()
      assert report[:host][:running_in_container] == true
    end
  end

  describe "when not running in a container" do
    setup do: @nif.set(:running_in_container?, false)

    test "outputs Container: no" do
      output = run()
      assert String.contains? output, "Container: no"
    end

    test "adds host running_in_container false to report" do
      run()
      report = received_report()
      assert report[:host][:running_in_container] == false
    end
  end

  describe "when not root user" do
    test "outputs root user: no" do
      output = run()
      assert String.contains? output, "root user: no"
    end

    test "adds host root false to report" do
      run()
      report = received_report()
      assert report[:host][:root] == false
    end
  end

  describe "when root user" do
    setup do: @system.set(:root, true)

    test "outputs warning about running as root" do
      output = run()
      assert String.contains? output, "root user: yes (not recommended)"
    end

    test "adds host root true to report" do
      run()
      report = received_report()
      assert report[:host][:root] == true
    end
  end

  @tag :skip_env_test_no_nif
  test "runs agent in diagnose mode" do
    @nif.set(:run_diagnose, true)
    output = run()
    assert String.contains? output, "Agent diagnostics"
    assert String.contains? output, "  Extension config: valid"
    assert String.contains? output, "  Agent started: started"
    assert String.contains? output, "  Agent config: valid"
    assert String.contains? output, "  Agent lock path: writable"
    assert String.contains? output, "  Agent logger: started"
  end

  @tag :skip_env_test_no_nif
  test "adds agent report to report" do
    @nif.set(:run_diagnose, true)
    run()
    report = received_report()
    assert report[:agent] == %{
      "agent" => %{
        "boot" => %{"started" => %{"result" => true}},
        "config" => %{"valid" => %{"result" => true}},
        "lock_path" => %{"created" => %{"result" => true}},
        "logger" => %{"started" => %{"result" => true}}
      },
      "extension" => %{
        "config" => %{"valid" => %{"result" => true}}
      }
    }
  end

  describe "when config is not active" do
    @tag :skip_env_test_no_nif
    test "runs agent in diagnose mode, but doesn't change the active state" do
      @nif.set(:run_diagnose, true)

      output = with_config(%{active: false}, &run/0)
      assert String.contains? output, "active: false"
      assert String.contains? output, "Agent diagnostics"
      assert String.contains? output, "  Extension config: valid"
      assert String.contains? output, "  Agent started: started"
      assert String.contains? output, "  Agent config: valid"
      assert String.contains? output, "  Agent lock path: writable"
      assert String.contains? output, "  Agent logger: started"
    end

    @tag :skip_env_test_no_nif
    test "adds agent report to report" do
      @nif.set(:run_diagnose, true)
      run()
      report = received_report()
      assert report[:agent] == %{
        "agent" => %{
          "boot" => %{"started" => %{"result" => true}},
          "config" => %{"valid" => %{"result" => true}},
          "lock_path" => %{"created" => %{"result" => true}},
          "logger" => %{"started" => %{"result" => true}}
        },
        "extension" => %{
          "config" => %{"valid" => %{"result" => true}}
        }
      }
    end
  end

  describe "when extension is not loaded" do
    setup do: @nif.set(:loaded?, false)

    test "agent diagnostics is not run" do
      output = run()
      assert String.contains? output, "Agent diagnostics"
      assert String.contains? output, "  Error: Nif not loaded, aborting."
    end

    test "adds no agent report to report" do
      run()
      assert received_report()[:agent] == nil
    end
  end

  describe "when extension output is invalid JSON" do
    setup do
      @nif.set(:loaded?, true)
      @nif.set(:diagnose, "agent_report_string")
    end

    test "agent diagnostics report prints an error" do
      output = run()
      assert String.contains? output, "Agent diagnostics"
      assert String.contains? output, "  Error: Could not parse the agent report:"
      assert String.contains? output, "    Output: agent_report_string"
    end

    test "adds agent output to report" do
      run()
      report = received_report()
      assert report[:agent] == %{output: "agent_report_string"}
    end
  end

  describe "when extension output is missing a test" do
    setup do
      @nif.set(:loaded?, true)
      @nif.set(:diagnose, ~s(
        {
          "extension": { "config": { "valid": { "result": true } } }
        }
      ))
    end

    test "agent diagnostics report prints the tests, but shows a dash `-` for missed results" do
      output = run()
      assert String.contains? output, "Agent diagnostics"
      assert String.contains? output, "  Extension config: valid"
      assert String.contains? output, "  Agent started: -"
      assert String.contains? output, "  Agent config: -"
      assert String.contains? output, "  Agent lock path: -"
      assert String.contains? output, "  Agent logger: -"
    end

    test "missings tests are not added to report" do
      run()
      assert received_report()[:agent] == %{
        "extension" => %{
          "config" => %{"valid" => %{"result" => true}}
        }
        # Missing agent report
      }
    end
  end

  describe "when the agent diagnose report contains an error" do
    setup do
      @nif.set(:loaded?, true)
      @nif.set(:diagnose, ~s({ "error": "fatal error" }))
    end

    test "prints the error" do
      output = run()
      assert String.contains? output, "Agent diagnostics\n  Error: fatal error"
    end

    test "adds the error to the report" do
      run()
      assert received_report()[:agent] == %{"error" => "fatal error"}
    end
  end

  describe "when an agent diagnose report test contains an error" do
    setup do
      @nif.set(:loaded?, true)
      @nif.set(:diagnose, ~s(
        {
          "agent": { "boot": { "started": { "result": false, "error": "my error" } } }
        }
      ))
    end

    test "prints the error" do
      output = run()
      assert String.contains? output, "Agent diagnostics"
      assert String.contains? output, "  Agent started: not started\n    Error: my error"
    end
  end

  describe "when an agent diagnose report test contains command output" do
    setup do
      @nif.set(:loaded?, true)
      @nif.set(:diagnose, ~s(
        {
          "agent": { "boot": { "started": { "result": false, "output": "my output" } } }
        }
      ))
    end

    test "prints the output" do
      output = run()
      assert String.contains? output, "Agent diagnostics"
      assert String.contains? output, "  Agent started: not started\n    Output: my output"
    end
  end

  test "outputs configuration" do
    output = run()
    assert String.contains? output, "Configuration"

    Enum.each Application.get_env(:appsignal, :config), fn({key, value}) ->
      assert String.contains? output, "  #{key}: #{value}"
    end
  end

  test "adds configuration to the report" do
    run()
    assert received_report()[:config] == Application.get_env(:appsignal, :config)
  end

  describe "with valid Push API key" do
    test "outputs invalid API key warning" do
      output = run()
      assert String.contains? output, "Validation"
      assert String.contains? output, "Push API key: valid"
    end

    test "adds validation to the report" do
      run()
      assert received_report()[:validation] == %{push_api_key: "valid"}
    end
  end

  describe "with invalid Push API key" do
    setup %{auth_bypass: auth_bypass} do
      setup_with_config(%{push_api_key: ""})
      Bypass.expect auth_bypass, fn conn ->
        assert "/1/auth" == conn.request_path
        assert "GET" == conn.method
        Plug.Conn.resp(conn, 401, "")
      end
    end

    test "outputs invalid API key warning" do
      output = run()
      assert String.contains? output, "Validation"
      assert String.contains? output, "Push API key: invalid"
    end

    test "adds validation to the report" do
      run()
      assert received_report()[:validation] == %{push_api_key: "invalid"}
    end
  end

  describe "without config" do
    test "it outputs tmp dir for log_dir_path" do
      output = with_config(%{log_path: nil}, &run/0)
      assert String.contains? output, "Paths"
      assert String.contains? output, "log_dir_path: /tmp"
      assert String.contains? output, "log_file_path: /tmp/appsignal.log"
    end

    test "adds paths to report" do
      run()
      assert Map.keys(received_report()[:paths]) == [:log_dir_path, :log_file_path]
    end
  end

  describe "when log_dir_path is writable" do
    setup do
      %{log_dir_path: log_dir_path, log_file_path: log_file_path} = prepare_tmp_dir "writable_path"

      {:ok, %{log_dir_path: log_dir_path, log_file_path: log_file_path}}
    end

    @tag :skip_env_test_no_nif
    test "outputs writable and creates log file", %{log_dir_path: log_dir_path, log_file_path: log_file_path} do
      @nif.set(:run_diagnose, true)
      output = run()
      assert String.contains? output, "log_dir_path: #{log_dir_path}\n    - Writable?: yes"
      assert String.contains? output, "log_file_path: #{log_file_path}\n    - Writable?: yes"
    end

    @tag :skip_env_test_no_nif
    test "adds writable log paths to report", %{log_dir_path: log_dir_path, log_file_path: log_file_path} do
      @nif.set(:run_diagnose, true)
      run()
      %{uid: uid} = File.stat!(log_dir_path)
      assert received_report()[:paths] == %{
        log_dir_path: %{
          path: log_dir_path,
          configured: true,
          exists: true,
          writable: true,
          ownership: %{uid: uid}
        },
        log_file_path: %{
          path: log_file_path,
          configured: true,
          exists: true,
          writable: true,
          ownership: %{uid: uid}
        }
      }
    end
  end

  describe "when log_dir_path does not exist" do
    setup do
      setup_with_config(%{log_path: "/foo/bar/baz.log"})
    end

    test "outputs exists: false" do
      output = run()

      assert String.contains? output, "log_dir_path: /foo/bar\n    - Exists?: no"
      assert String.contains? output, "log_file_path: /foo/bar/baz.log\n    - Exists?: no"
    end

    test "adds log exists: false to report" do
      run()
      log_dir_report = received_report()[:paths][:log_dir_path]
      assert log_dir_report[:exists] == false
      assert log_dir_report[:writable] == false
      log_file_report = received_report()[:paths][:log_file_path]
      assert log_file_report[:exists] == false
      assert log_file_report[:writable] == false
    end
  end

  describe "when log_dir_path is not writable" do
    setup do
      log_dir_path = Path.expand("tmp/not_writable_path", File.cwd!)
      log_file_path = Path.expand("appsignal.log", log_dir_path)
      on_exit :clean_up, fn ->
        File.chmod!(log_dir_path, 0o755)
        File.rm_rf!(log_dir_path)
      end

      File.mkdir_p!(log_dir_path)
      File.touch!(log_file_path)
      File.chmod!(log_dir_path, 0o400)
      setup_with_config(%{log_path: log_file_path})

      {:ok, %{log_dir_path: log_dir_path, log_file_path: log_file_path}}
    end

    test "outputs writable: false", %{log_dir_path: log_dir_path, log_file_path: log_file_path} do
      output = run()

      assert String.contains? output, "log_dir_path: #{log_dir_path}\n    - Writable?: no"
      # Can't read inside the directory so it's assumed to not exist
      assert String.contains? output, "log_file_path: #{log_file_path}\n    - Exists?: no"
    end

    test "adds log writable: false to report" do
      run()
      log_dir_report = received_report()[:paths][:log_dir_path]
      assert log_dir_report[:exists] == true
      assert log_dir_report[:writable] == false
      log_file_report = received_report()[:paths][:log_file_path]
      assert log_file_report[:exists] == false
      assert log_file_report[:writable] == false
    end
  end

  describe "when path is owned by current user" do
    setup do
      %{log_dir_path: log_dir_path} = prepare_tmp_dir "not_owned_path"
      %{uid: uid} = File.stat!(log_dir_path)

      {:ok, %{log_dir_path: log_dir_path, uid: uid}}
    end

    test "outputs ownership uid", %{log_dir_path: log_dir_path, uid: uid} do
      @system.set(:uid, uid)
      output = run()
      assert String.contains? output, "log_dir_path: #{log_dir_path}\n    - Writable?: yes\n" <>
        "    - Ownership?: yes (file: #{uid}, process: #{@system.uid})"
    end
  end

  describe "when path is not owned by current user" do
    setup do
      %{log_dir_path: log_dir_path} = prepare_tmp_dir "owned_path"

      {:ok, %{log_dir_path: log_dir_path}}
    end

    test "outputs ownership uid", %{log_dir_path: log_dir_path} do
        %{uid: uid} = File.stat!(log_dir_path)
        output = run()
        assert String.contains? output, "log_dir_path: #{log_dir_path}\n    - Writable?: yes\n" <>
          "    - Ownership?: no (file: #{uid}, process: #{@system.uid})"
      end
  end

  describe "when user does not submit report to AppSignal" do
    test "exits early" do
      output = run("n")
      assert String.contains? output, "Diagnostics report"
      assert String.contains? output, "Send diagnostics report to AppSignal? (Y/n):"
      assert String.contains? output, "Not sending diagnostics report to AppSignal."

      refute @diagnose_report.get(:report_sent?)
    end
  end

  describe "when user submits report to AppSignal" do
    test "sends diagnostics report to AppSignal and outputs a support token" do
      assert @diagnose_report.set(:response, {:ok, "0123456789abcdef"})
      output = run()
      assert String.contains? output, "Diagnostics report"
      assert String.contains? output, "Send diagnostics report to AppSignal? (Y/n):"
      assert String.contains? output, "Transmitting diagnostics report"
      assert String.contains? output, "Your diagnostics report has been sent to AppSignal."
      assert String.contains? output, "Your support token: 0123456789abcdef"

      assert @diagnose_report.get(:report_sent?)
      assert received_report()
    end

    test "when returns invalid output it outputs an error" do
      assert @diagnose_report.set(:response, {:error, %{status_code: 200, body: "foo"}})
      output = run()
      assert String.contains? output, "Diagnostics report"
      assert String.contains? output, "Send diagnostics report to AppSignal? (Y/n):"
      assert String.contains? output, "Transmitting diagnostics report"
      assert String.contains? output, "Error: Couldn't decode server response."
      assert String.contains? output, "Response body: foo"
    end

    test "when server errors it outputs an error" do
      assert @diagnose_report.set(:response, {:error, %{status_code: 500, body: "foo"}})
      output = run()
      assert String.contains? output, "Diagnostics report"
      assert String.contains? output, "Send diagnostics report to AppSignal? (Y/n):"
      assert String.contains? output, "Transmitting diagnostics report"
      assert String.contains? output, "Error: Something went wrong while submitting the report " <>
        "to AppSignal."
      assert String.contains? output, "Response code: 500"
      assert String.contains? output, "Response body: foo"
    end

    test "when no connection to server it outputs an error" do
      assert @diagnose_report.set(:response, {:error, %{reason: "foo"}})
      output = run()
      assert String.contains? output, "Diagnostics report"
      assert String.contains? output, "Send diagnostics report to AppSignal? (Y/n):"
      assert String.contains? output, "Transmitting diagnostics report"
      assert String.contains? output, "Error: Something went wrong while submitting the report " <>
        "to AppSignal.\nfoo"
    end
  end

  defp prepare_tmp_dir(path) do
    log_dir_path = Path.expand("tmp/#{path}", File.cwd!)
    log_file_path = Path.expand("appsignal.log", log_dir_path)
    on_exit :clean_up, fn ->
      File.rm_rf!(log_dir_path)
    end

    File.mkdir_p!(log_dir_path)
    setup_with_config(%{log_path: log_file_path})

    %{log_dir_path: log_dir_path, log_file_path: log_file_path}
  end
end
