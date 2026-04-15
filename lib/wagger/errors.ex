defmodule Wagger.Errors do
  @moduledoc """
  Registered error codes for the Wagger application.

  Uses `Comn.Errors.Registry` to declare machine-readable error codes
  that are discoverable at runtime. All codes use the `wagger.*` namespace.
  """

  use Comn.Errors.Registry

  # -- Generator pipeline --

  register_error "wagger.generator/yang_parse_failed", :internal,
    message: "Failed to parse YANG schema"

  register_error "wagger.generator/yang_resolve_failed", :internal,
    message: "Failed to resolve YANG schema"

  register_error "wagger.generator/validation_failed", :validation,
    message: "Instance data failed YANG schema validation"

  register_error "wagger.generator/unknown_provider", :validation,
    message: "Unknown provider name",
    status: 400

  register_error "wagger.generator/serialization_failed", :internal,
    message: "Failed to serialize provider config"

  # -- Accounts --

  register_error "wagger.accounts/user_creation_failed", :validation,
    message: "Could not create user"

  register_error "wagger.accounts/auth_failed", :auth,
    message: "Invalid or missing API key",
    status: 401

  register_error "wagger.accounts/protected_user", :auth,
    message: "Cannot delete the admin user",
    status: 403

  # -- Snapshots --

  register_error "wagger.snapshots/decryption_failed", :internal,
    message: "Failed to decrypt snapshot output"

  register_error "wagger.snapshots/creation_failed", :persistence,
    message: "Failed to create snapshot"

  # -- Secrets --

  register_error "wagger.secrets/encryption_failed", :internal,
    message: "Failed to encrypt data"

  register_error "wagger.secrets/key_generation_failed", :internal,
    message: "Failed to generate or load encryption key"

  # -- Applications --

  register_error "wagger.applications/not_found", :validation,
    message: "Application not found",
    status: 404

  register_error "wagger.applications/not_shareable", :validation,
    message: "Application is not public and shareable",
    status: 404

  register_error "wagger.applications/name_taken", :validation,
    message: "Application name is already taken",
    status: 409

  register_error "wagger.applications/protected", :auth,
    message: "Cannot delete a protected application",
    status: 403
end
