# YouRec development

- For changes to capture framing, orientation, sensor formats, or encoding, read
  and follow `docs/CAMERA-QA.md`. Completion requires physical evidence from the
  affected camera, including the visible preview and saved recording. Synthetic
  simulator frames validate layout only. A locked device leaves camera acceptance
  pending; do not treat another successful build as a substitute.
- Use the iPhone 14 for ordinary device development. Use the iPhone 17 Pro for
  behavior specific to its camera. Install in place and preserve user projects.
- Before device diagnostics, snapshot project manifests/inventory and any recorder
  preferences the diagnostic changes. Keep test recordings outside Projects.
- For every device cleanup, including editor tests, follow the Device artifact
  cleanup section of `docs/CAMERA-QA.md`. Never pass `--remove-existing-content`
  to `devicectl device copy to` on an app container. It can erase the entire
  container even when the destination names a single test folder.
- Validate the public gesture or control for interaction fixes, as well as the
  underlying model. Review the final result after the last relevant code change.
