"""Execute Make recipes with stubbed CLIs; no Azure or Terraform operations."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
SUBSCRIPTION = "11111111-2222-3333-4444-555555555555"

pytestmark = pytest.mark.skipif(not shutil.which("make"), reason="GNU Make is required")


def test_backend_settings_are_ignored_but_examples_can_be_committed():
    result = subprocess.run(
        ["git", "check-ignore", "--no-index", "--stdin"],
        input="\n".join([
            "environments/dev/backend.json",
            "environments/qa/backend.json",
            "environments/dev/backend.json.example",
            "environments/dev/terraform.tfvars.example",
        ]) + "\n",
        cwd=ROOT, text=True, capture_output=True, timeout=30, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [
        "environments/dev/backend.json",
        "environments/qa/backend.json",
    ]
    example = json.loads((ROOT / "environments/dev/backend.json.example").read_text())
    for key in ("resource_group_name", "storage_account_name", "container_name"):
        assert example[key].startswith("<") and example[key].endswith(">")
    assert example["use_azuread_auth"] is True


def test_dev_example_selects_foundry_without_local_models_or_container_apps():
    import re

    example = (ROOT / "environments/dev/terraform.tfvars.example").read_text()
    for name in ("deployModelDeployments", "deployContainerApps", "deployContainerEnv"):
        assert re.search(rf"^{name}\s*=\s*false$", example, re.MULTILINE)


def test_dev_example_creates_an_isolated_network_in_canada_east():
    import re

    example = (ROOT / "environments/dev/terraform.tfvars.example").read_text()
    selections = {
        "location": '"canadaeast"',
        "privateEndpointLocation": '"canadaeast"',
        "useExistingVNet": "false",
        "networkIsolation": "true",
        "deploySubnets": "true",
        "deployAiFoundrySubnet": "true",
        "deploymentMode": '"standalone"',
        "deployAzureFirewall": "false",
        "deployAcrTaskAgentPool": "false",
        "deployJumpbox": "false",
        "deployBastion": "false",
        "deployNatGateway": "false",
    }
    for name, value in selections.items():
        assert re.search(rf"^{name}\s*=\s*{re.escape(value)}$", example, re.MULTILINE)
    for name in (
        "existingVnetResourceId", "existingVnetSubscriptionId", "networkResourceGroupName",
        "privateEndpointResourceGroupName", "agentSubnetName", "peSubnetName",
        "applicationPeSubnetName",
    ):
        assert not re.search(rf"^{name}\s*=", example, re.MULTILINE)


@pytest.fixture
def runner(tmp_path):
    log = tmp_path / "commands.jsonl"
    terraform = tmp_path / "terraform"
    terraform.write_text(
        f"#!{sys.executable}\n"
        "import json, os, pathlib, sys\n"
        "with open(os.environ['COMMAND_LOG'], 'a') as stream:\n"
        "    stream.write(json.dumps({'args': sys.argv[1:], 'data': os.environ['TF_DATA_DIR']}) + '\\n')\n"
        "if os.environ.get('FAIL_COMMAND') in sys.argv[1:]:\n"
        "    sys.exit(7)\n",
        encoding="utf-8",
    )
    terraform.chmod(0o755)
    az = tmp_path / "az"
    az.write_text(f"#!{sys.executable}\nprint('{SUBSCRIPTION}')\n", encoding="utf-8")
    az.chmod(0o755)
    (tmp_path / "infra/terraform").mkdir(parents=True)

    def run(target, *, environment="dev", inputs=True, extra_env=None):
        directory = tmp_path / "environments" / environment
        directory.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "environments/dev/backend.json.example", directory / "backend.json")
        if inputs:
            (directory / "terraform.tfvars").write_text(
                f'subscriptionId = "{SUBSCRIPTION}"\n', encoding="utf-8",
            )
        process_environment = {
            key: value for key, value in os.environ.items()
            if key not in {"ARM_ACCESS_KEY", "ARM_SAS_TOKEN", "MAKEFLAGS", "MAKELEVEL"}
        }
        process_environment.update(COMMAND_LOG=str(log), **(extra_env or {}))
        result = subprocess.run(
            [
                "make", "--no-print-directory", "-f", str(ROOT / "Makefile"),
                f"ROOT_DIR={tmp_path}", f"TERRAFORM={terraform}", f"AZ={az}",
                f"ENV={environment}", target,
            ],
            cwd=tmp_path, env=process_environment, text=True, capture_output=True,
            timeout=30, check=False,
        )
        commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, commands

    return run, tmp_path


def test_bootstrap_initializes_existing_backend_without_azd_or_inputs(runner):
    run, root = runner
    result, commands = run("bootstrap", inputs=False)
    assert result.returncode == 0, result.stderr
    assert len(commands) == 1
    args = commands[0]["args"]
    assert args[:2] == [f"-chdir={root}/infra/terraform", "init"]
    assert f"-backend-config={root}/environments/dev/backend.json" in args
    assert "-backend-config=use_azuread_auth=true" in args
    assert "-lockfile=readonly" in args
    assert not any(arg in args for arg in ("-reconfigure", "-migrate-state", "-force-copy"))
    assert not (root / ".azure").exists()


def test_apply_creates_a_fresh_plan_then_applies_that_exact_file(runner):
    run, root = runner
    result, commands = run("apply")
    assert result.returncode == 0, result.stderr
    assert [command["args"][1] for command in commands] == ["init", "plan", "apply"]
    plan = str(root / "environments/dev/platform.tfplan")
    assert f"-out={plan}" in commands[1]["args"]
    assert commands[2]["args"][-1] == plan
    assert f"-var-file={root}/environments/dev/terraform.tfvars" in commands[1]["args"]
    assert all("-lock=false" not in command["args"] for command in commands)
    assert all(command["data"] == str(root / ".terraform/environments/dev") for command in commands)


@pytest.mark.parametrize("failure", ["init", "plan"])
def test_failure_stops_before_apply(runner, failure):
    run, _ = runner
    result, commands = run("apply", extra_env={"FAIL_COMMAND": failure})
    assert result.returncode != 0
    assert "apply" not in [command["args"][1] for command in commands]


def test_missing_inputs_stop_before_initialization(runner):
    run, _ = runner
    result, commands = run("plan", inputs=False)
    assert result.returncode != 0
    assert "Missing" in result.stderr
    assert commands == []


def test_subscription_mismatch_stops_before_initialization(runner):
    run, root = runner
    az = root / "az"
    az.write_text(f"#!{sys.executable}\nprint('another-subscription')\n", encoding="utf-8")
    result, commands = run("plan")
    assert result.returncode != 0
    assert "subscription differs" in result.stderr
    assert commands == []


@pytest.mark.parametrize("credential", ["ARM_ACCESS_KEY", "ARM_SAS_TOKEN"])
def test_backend_shared_key_overrides_are_rejected(runner, credential):
    run, _ = runner
    result, commands = run("init", extra_env={credential: "sentinel-secret"})
    assert result.returncode != 0
    assert "state requires Entra authentication" in result.stderr
    assert "sentinel-secret" not in result.stderr
    assert commands == []


def test_validate_has_an_isolated_cache_and_does_not_initialize_remote_state(runner):
    run, root = runner
    result, commands = run("validate")
    assert result.returncode == 0, result.stderr
    assert [command["args"][1] for command in commands] == ["fmt", "init", "validate"]
    assert "-backend=false" in commands[1]["args"]
    assert all(command["data"] == str(root / ".terraform/validate") for command in commands)


def test_environments_have_separate_caches_and_plan_files(runner):
    run, root = runner
    result, commands = run("plan", environment="qa")
    assert result.returncode == 0, result.stderr
    assert commands[-1]["data"] == str(root / ".terraform/environments/qa")
    assert f"-out={root}/environments/qa/platform.tfplan" in commands[-1]["args"]


def test_environment_named_validate_does_not_share_the_validation_cache(runner):
    run, root = runner
    result, commands = run("init", environment="validate")
    assert result.returncode == 0, result.stderr
    assert commands[0]["data"] == str(root / ".terraform/environments/validate")


def test_environment_cannot_escape_its_directory(runner):
    run, _ = runner
    result, commands = run("init", environment="../other")
    assert result.returncode != 0
    assert "ENV must contain" in result.stderr
    assert commands == []
