import share_handler_ios_models

// The whole Share Extension is provided by share_handler: ShareHandlerIosViewController
// picks up the shared items, writes them into the app group, and redirects into
// the host app via the `ShareMedia-<bundleId>` URL scheme, where the Dart side
// (share_target_listener) takes over. We only need this empty subclass.
class ShareViewController: ShareHandlerIosViewController {}
