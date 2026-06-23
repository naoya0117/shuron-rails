# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "yaml"
require_relative "../../lib/rails/kubernetes/manifest_annotator"

class ManifestAnnotatorTest < Minitest::Test
  FIXTURE = {
    "apiVersion" => "apps/v1",
    "kind"       => "Deployment",
    "spec" => {
      "terminationGracePeriodSeconds" => 60,
      "template" => {
        "spec" => {
          "containers" => [
            {
              "name" => "web",
              "resources" => {
                "requests" => { "cpu" => "100m" },
                "limits"   => { "memory" => "256M" }
              },
              "livenessProbe"  => { "httpGet" => { "path" => "/k/live",  "port" => 3000 } },
              "readinessProbe" => { "httpGet" => { "path" => "/k/ready", "port" => 3000 } }
            }
          ]
        }
      }
    }
  }

  def setup
    @file = Tempfile.new(["web-deployment", ".yaml"])
    @file.write(YAML.dump(FIXTURE))
    @file.close
  end

  def teardown
    @file.unlink
  end

  def test_inject_pre_stop_adds_lifecycle_to_container
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s")
    manifest = YAML.load_file(@file.path)
    pre_stop = manifest.dig("spec", "template", "spec", "containers", 0, "lifecycle", "preStop")
    assert_equal({ "exec" => { "command" => ["sleep", "15"] } }, pre_stop)
  end

  def test_inject_pre_stop_strips_seconds_suffix
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "30s")
    manifest = YAML.load_file(@file.path)
    cmd = manifest.dig("spec", "template", "spec", "containers", 0, "lifecycle", "preStop", "exec", "command")
    assert_equal ["sleep", "30"], cmd
  end

  def test_inject_pre_stop_accepts_plain_number
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15")
    manifest = YAML.load_file(@file.path)
    cmd = manifest.dig("spec", "template", "spec", "containers", 0, "lifecycle", "preStop", "exec", "command")
    assert_equal ["sleep", "15"], cmd
  end

  def test_comments_inserted_for_all_framework_sections
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s")
    text = File.read(@file.path)
    assert_includes text, "# shuron-rails Kubernetes layer (Graceful Shutdown)"
    assert_includes text, "# shuron-rails Kubernetes layer (Predictable Demands)"
    assert_includes text, "# shuron-rails Kubernetes layer (Health Probe)"
    assert_includes text, "# shuron-rails Kubernetes layer (Graceful Shutdown - injected after kompose)"
  end

  def test_comments_match_indentation_of_target_key
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s")
    lines = File.readlines(@file.path)
    lines.each_with_index do |line, i|
      next unless line.match?(/# shuron-rails/)
      next_line = lines[i + 1]
      comment_indent = line[/\A\s*/]
      key_indent    = next_line[/\A\s*/]
      assert_equal comment_indent, key_indent,
        "Comment indent (#{comment_indent.length}) != key indent (#{key_indent.length})\nLine: #{line.inspect}\nNext: #{next_line.inspect}"
    end
  end

  def test_missing_containers_does_not_raise
    bad = Tempfile.new(["bad", ".yaml"])
    bad.write(YAML.dump({ "spec" => {} }))
    bad.close
    Rails::Kubernetes::ManifestAnnotator.annotate!(bad.path, pre_stop_delay: "15s")
    pass
  ensure
    bad.unlink
  end

  # Process Containment: securityContext injection -------------------------

  SECURITY = {
    run_as_non_root: true,
    allow_privilege_escalation: false,
    drop_capabilities: ["ALL"]
  }.freeze

  def test_injects_secure_default_security_context
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s", security: SECURITY)
    sc = container_security_context
    assert_equal true, sc["runAsNonRoot"]
    assert_equal false, sc["allowPrivilegeEscalation"]
    assert_equal({ "drop" => ["ALL"] }, sc["capabilities"])
  end

  def test_read_only_root_filesystem_is_opt_in
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s", security: SECURITY)
    refute container_security_context.key?("readOnlyRootFilesystem"), "must stay off unless requested"

    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s",
      security: SECURITY.merge(read_only_root_filesystem: true))
    assert_equal true, container_security_context["readOnlyRootFilesystem"]
  end

  def test_security_context_does_not_clobber_existing_values
    manifest = YAML.load_file(@file.path)
    manifest["spec"]["template"]["spec"]["containers"][0]["securityContext"] = { "runAsNonRoot" => false }
    File.write(@file.path, YAML.dump(manifest))

    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s", security: SECURITY)
    sc = container_security_context
    assert_equal false, sc["runAsNonRoot"], "user-set value must win"
    assert_equal false, sc["allowPrivilegeEscalation"], "still fills the unset keys"
  end

  def test_security_can_be_disabled
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s",
      security: { enabled: false })
    refute container.key?("securityContext")
  end

  def test_no_security_argument_leaves_manifest_untouched
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s")
    refute container.key?("securityContext"), "backward compatible: no security arg => no injection"
  end

  def test_process_containment_comment_inserted
    Rails::Kubernetes::ManifestAnnotator.annotate!(@file.path, pre_stop_delay: "15s", security: SECURITY)
    assert_includes File.read(@file.path), "# shuron-rails Kubernetes layer (Process Containment - injected after kompose)"
  end

  private
    def container
      YAML.load_file(@file.path).dig("spec", "template", "spec", "containers", 0)
    end

    def container_security_context
      container.fetch("securityContext")
    end
end
