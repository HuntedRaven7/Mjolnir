@mjolnir @e2e
Feature: Mjolnir boots and reports its identity
  The image boots from a disk installed with `bootc install to-disk` and
  exposes its state over the mTLS Varlink API. No shell or SSH is used.

  @boot
  Scenario: The node reaches the ready sentinel
    Given the image is installed to a disk with bootc
    When the VM boots with Secure Boot disabled for CI
    Then /run/mjolnir/ready appears on the serial console within 180 seconds

  @bootc
  Scenario: bootc status reports the expected image
    Given the node is running
    When the runner calls io.mjolnir.Fleet.Status over Varlink
    Then the image field equals the image under test
    And the version field is not empty

  @health
  Scenario: No failed systemd units at boot
    Given the node is running
    When the runner reads the unit state over the serial console
    Then no unit is in the failed state

  @immutability
  Scenario: The system root is read-only
    Given the node is running
    When the runner inspects mounts over the serial console
    Then /usr is mounted read-only
    And the booted deployment matches the verity-pinned image

  @fleet
  Scenario: Fleet state is published
    Given the node is running and has a fleet credential
    When the runner reads the MjolnirNode resource
    Then status.version equals the booted version
    And status.wifi has an interface field

  @selinux
  Scenario: SELinux is enforcing with no AVC denials
    Given the image ships an SELinux policy
    When the runner inspects enforcement state over the serial console
    Then SELinux is enforcing and no AVC denials are present

  @provenance
  Scenario: The published image has a valid keyless signature
    Given the image is published to GHCR
    When the runner verifies it with cosign
    Then the OIDC issuer is GitHub Actions
    And the identity matches this repository's workflow
