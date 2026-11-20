@mjolnir @e2e @impermanence
Feature: Impermanent root behaves as designed
  /etc and /var are tmpfs each boot; the allowlist is re-attached from the
  persistent MjolnirState partition.

  @volatile
  Scenario: systemd.volatile=yes is active
    Given the node is running
    Then /proc/cmdline contains "systemd.volatile=yes"
    And /etc and /var are mounted on tmpfs

  @machine-id
  Scenario: machine-id is stable across two reboots
    Given the node has booted at least twice
    When the runner reads /etc/machine-id from the serial console
    Then it equals the value recorded on the first boot

  @persist
  Scenario: Allowlisted state survives a reboot
    Given containerd and kubelet state were written before reboot
    When the node reboots
    Then /var/lib/containerd and /var/lib/kubelet still contain that state
    And /var/log/journal still contains entries from the previous boot

  @ephemeral
  Scenario: Non-allowlisted state is wiped on reboot
    Given a marker file was written to /var/tmp before reboot
    When the node reboots
    Then the marker file no longer exists

  @kured
  Scenario: A staged update signals kured and the node returns
    Given bootc has staged an update
    When /run/reboot-required is created via Varlink
    Then kured cordons and drains the node
    And the node reboots and returns to Ready with the new version
