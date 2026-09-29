import Foundation

/// Built-in strings for this module.
///
/// A `LocalizedStringKey` passed to `Text` is looked up in `Bundle.main`,
/// which does not contain this package's strings; the lookup would silently
/// return the key. `LocalizedStringResource` carries this module's bundle.
extension LocalizedStringResource {
    /// A string from this module's String Catalog. `#bundle` refers to this
    /// module, so the helper must be defined here.
    static func module(
        _ keyAndValue: String.LocalizationValue,
        comment: StaticString? = nil
    ) -> LocalizedStringResource {
        LocalizedStringResource(keyAndValue, bundle: .atURL(#bundle.bundleURL), comment: comment)
    }
}

extension String {
    /// The same lookup, resolved to a `String`.
    static func module(
        localized keyAndValue: String.LocalizationValue,
        comment: StaticString? = nil
    ) -> String {
        String(localized: keyAndValue, bundle: #bundle, comment: comment)
    }
}
