# Localization contributor guide

QuickFile uses Apple's String Catalog (`Resources/Localizable.xcstrings`). The source language is Simplified Chinese (`zh-Hans`); English (`en`) is also shipped. The app and Finder extension bundle the same catalog. Translators do not need to edit Swift code or install a translation service.

## Contribute a translation

For an existing language, edit its column in Xcode's String Catalog editor and submit the catalog diff. Read each entry's English context comment: it identifies the feature and explains interpolated arguments. Ask about ambiguous wording before marking it translated. Include the affected screen and a screenshot when text does not fit; use synthetic names and paths in screenshots.

Contributors who prefer a translation package can request an `.xcloc` from the maintainer, translate it in Xcode or an XLIFF-compatible editor, and return the package. The maintainer exports and imports using Xcode's native tools in an isolated working copy (export also synchronizes the source catalog):

```sh
xcodebuild -exportLocalizations -project QuickFile.xcodeproj -scheme QuickFile \
  -localizationPath .build/Temporary/localization-exchange/export -exportLanguage en \
  -derivedDataPath .build/Temporary/localization-exchange/DerivedData \
  -clonedSourcePackagesDirPath .build/Temporary/localization-exchange/SourcePackages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
xcodebuild -importLocalizations -project QuickFile.xcodeproj -scheme QuickFile \
  -localizationPath .build/Temporary/localization-exchange/export/en.xcloc \
  -derivedDataPath .build/Temporary/localization-exchange/DerivedData \
  -clonedSourcePackagesDirPath .build/Temporary/localization-exchange/SourcePackages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
```

Replace `en` with the requested language. Keep export/build files in the task's `.build/Temporary/` directory. Both operations can trigger a build; retain the explicit cache paths and signing overrides. Do not run exchange operations concurrently with packaging in the same working copy. Import into a reviewable working copy, inspect the catalog and project diff, and run the checks below. Do not send personal templates, bookmarks, diagnostic exports, or production data to translators. Standard exports contain source strings/comments; inspect their contents before sharing them.

A new-language contribution should identify a person willing to review future wording updates. Before release, the maintainer lists changed strings, requests review of their context and grammar, then checks the returned catalog and layout evidence. Machine translation can be a draft; a translated state is not evidence of a native speaker's review.

## Add a language

1. Add a BCP-47 identifier, such as `fr`, to `options.knownRegions` in `project.yml` and add the language in Xcode's String Catalog editor.
2. Translate every entry and mark it translated. Preserve argument identities and types, identifiers, template-variable tokens, and literal commands. Do not translate user template contents, paths, or filenames.
3. Run `xcodegen generate` and include the generated project with the catalog and `project.yml`. After an Xcode import, reconcile language changes in `project.yml` before regenerating. The picker discovers shipped languages and uses their native names; no Swift language branch needs adding.
4. Run `python3 Scripts/verify-localizations.py`, `python3 -m unittest Scripts.tests.test_localizations`, and `Scripts/verify-release-readiness.sh`. The release guard checks compiler-extracted keys and translations shipped in both bundles.
5. Review the installed language using `BETA_TEST_GUIDE.md`. Resource completeness does not prove correct layout or runtime switching. An RTL language needs explicit direction/layout acceptance before shipping.

`knownRegions`, catalog languages, and complete translated entries must agree. Keep draft translations outside the shipping catalog until complete. An unknown saved language is reported as invalid settings and can be explicitly repaired; it is never silently written over.

## Terminology and writing

| Source term | English | Meaning |
| --- | --- | --- |
| 模板 | Template | Saved recipe for creating a file; not the created document. |
| 模板正文 | Template content | Literal text stored by the user; never translate it. |
| 默认文件名 | Default filename | Per-template suggested filename, separate from the template's display name. |
| 文件夹授权 / 保存的目录授权 | Folder access / Saved folder access | Access granted to a selected folder; not full disk access. |
| 本地共享存储 | Local shared storage | Data shared by QuickFile and its Finder extension on this Mac. |
| 恢复 | Recover / Restore | Recover missing/damaged configuration; restore built-in defaults. Use the operation's context. |
| 归档请求 | Archive request | Preserve one request locally and remove it from the pending queue; not delete all requests. |
| 停用 / 启用 | Disabled / Enabled | State labels. Use Disable / Enable for actions. |

Keep QuickFile, Finder, Word, Excel, PowerPoint, filename extensions, UUIDs, commands, and `{{filename}}` / `{{clipboard}}` tokens literal. Translate complete sentences; preserve each safety consequence, cancellation scope, and whether an action has already succeeded. Never infer new permissions or successful creation from a registration/status message. Use consistent macOS terminology and punctuation.

## Add or change UI text

SwiftUI literals such as `Text("创建文件")` remain the normal choice for static interface text. Use `Text(verbatim:)` for user data. For AppKit, errors and computed strings, use a native resource through the shared resolver:

```swift
QuickFileLocalization.text(.init("模板已重新加载。",
    comment: "Success feedback after reloading the template library."))

let result: LocalizedStringResource = .init("template.import.appended",
    defaultValue: "已追加导入 \(addedCount) 个模板。",
    comment: "Import completion. Count is newly added templates, not total library size.")
// Retain the resource as a value; resolve it when displaying the result.
QuickFileLocalization.text(result)
```

The resolver applies the current language to the resource's locale. Foundation then selects its translation and plural rules together. Explicit `.init` calls let Xcode extract keys and comments. Do not add a wrapper accepting a plain `String` or a custom translation dictionary. Use semantic keys for reusable/parameterized messages when they clarify meaning; existing literal keys need no mass renaming. The validator compares arguments with the source-language **value**, not the key.

Every translatable catalog entry requires a useful English comment. The intentional empty UI label is explicitly marked non-translatable; no other product text may use that marker. State the screen/operation and explain each argument in source order (for example, imported count versus total count). Describe ambiguous short labels as actions, states or titles. Comments can be authored in Swift or in the catalog; retain them when editing translations. Do not fill them with the key or an unrelated generic sentence.

A view rendering computed strings must depend on `@Environment(\.locale)`, including nested sections: a parent's dependency does not invalidate an unchanged child. Test the retained hosted view's displayed text across both switch directions without reloading or saving its model; testing the string getter alone misses stale UI. For `ForEach`-backed picker options, resolve display names into its input values; an unchanged model collection can otherwise retain cached labels across locale changes. Keep stable template IDs as tags and preserve the selected template and filename draft. `AppTabsView` forwards that environment across native hosting boundaries and updates toolbar metadata without replacing page controllers. The app's explicit language selection is shared with Finder. System mode uses Foundation's preferred-language list; macOS per-app settings are inputs to the host's system-language resolution. Switching QuickFile's own language must not write `AppleLanguages` or change global system preferences.

Store operation facts, native resources, or existing error types; render their descriptions when needed. Settings models retain errors and save outcomes, and template persistence helpers take `LocalizedStringResource` values. Do not cache rendered strings in `static let` or model state. Existing `LocalizedPresentation` sites are transitional: their closures must be pure and capture only immutable operation facts, never a model, mutable draft, security-scope token, or work to repeat. Prefer semantic result types for new feedback.

Finder menu labels remain precomputed for all shipped languages at extension startup. Their explicit-bundle lookups intentionally bypass the current-language resolver. Do not add resource loads, compilation or settings reads to the menu callback. Resource bundles for bounded precomputed labels and native toolbar updates are also deliberate exceptions to the normal resolver.

## Validation and acceptance

The guard checks comments, complete translations, template-variable tokens and argument identities/types. Positional reordering is allowed (`%lld … %@` → `%2$@ … %1$lld`); do not mix positioned and sequential arguments. Literal percent signs use `%%` in format strings.

Single-count plural variations require `other` and the count placeholder in each form. Provide the forms required by the target language; checking for `other` alone does not certify its grammar. Artifact checks compare Apple's compiled `.stringsdict` in both bundles. Device variations and multi-variable `substitutions` are not supported by the current guard: extend validation with a representative fixture before using them.

For runtime acceptance, switch languages with an existing success/error message visible and a draft open, then switch back. Check that text changes, drafts survive, and saving/creating does not repeat. Reopen the app and a Finder menu with the app closed. Check native toolbar labels, sheets, Settings, accessibility labels and user-defined template names. Test counts such as 0, 1, 2 and larger values, including a region different from the chosen interface language.

Include both folder-access failure paths: saving a Finder grant and loading saved grants. Retain the underlying error and derive the displayed state from it; a comparable presentation enum must not become a cache of translated errors. Regression tests must switch in both directions without repeating the bookmark operation or inventory read, and verify that retry or a destination change clears the appropriate failure state.

Use Xcode's Double-Length Pseudolanguage to inspect truncation and Right-to-Left Pseudolanguage to inspect direction; also review the actual target language. Keep the app set to System for scheme-driven language tests and verify which locale actually resolved. An explicit `.lproj` precomputed cache may bypass pseudolanguage transformation: those Finder/toolbar surfaces still need long-label testing with real or temporary test-only resources. Do not add a test language to the shipping catalog or infer visual acceptance from catalog tests.

## Built-in names and user data

`FileTemplate.name` remains persisted user data. `displayName` localizes it only when both its fixed built-in ID and a known built-in name match. Renamed/custom templates keep literal names. Creation pickers, lists, search and Finder use this projection; editing and export retain stored values. Language changes must not write templates, replace IDs, change default filenames or rewrite content.

Keep built-in IDs stable. Before changing a built-in translation, retain its old spelling as an explicit compatibility alias; otherwise saved defaults can be mistaken for custom names. OS-owned controls and underlying OS error details use the system's localization, while surrounding QuickFile text uses the chosen app language.
