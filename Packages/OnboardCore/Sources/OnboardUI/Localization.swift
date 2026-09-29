import Foundation

/// Every built-in string in this module resolves through here.
///
/// The bundle is the whole point. These views live in a Swift package, not in
/// the app target, so a `LocalizedStringKey` handed to `Text` is looked up in
/// `Bundle.main` — the *app's* catalog — where our keys do not exist. The
/// lookup then fails silently and returns the key itself, which in English
/// reads exactly like a correct translation. Nothing would look wrong until
/// someone ran the Mac in Dutch.
///
/// `LocalizedStringResource` is the type that carries its bundle with it, so
/// resolution stays deferred to display time (honouring the locale in effect
/// then) and lands in this module's catalog wherever the string is finally
/// rendered.
extension LocalizedStringResource {
    /// A string from `OnboardUI`'s own String Catalog.
    ///
    /// `#bundle` resolves to the bundle of the target this file belongs to,
    /// which is why the helper has to live *in* the module rather than be
    /// passed one.
    static func module(
        _ keyAndValue: String.LocalizationValue,
        comment: StaticString? = nil
    ) -> LocalizedStringResource {
        LocalizedStringResource(keyAndValue, bundle: .atURL(#bundle.bundleURL), comment: comment)
    }
}

extension String {
    /// The same lookup for the handful of places that genuinely need a
    /// resolved `String` rather than a deferred resource: a view model
    /// property whose other source is a plain `String` from the profile.
    static func module(
        localized keyAndValue: String.LocalizationValue,
        comment: StaticString? = nil
    ) -> String {
        String(localized: keyAndValue, bundle: #bundle, comment: comment)
    }
}
