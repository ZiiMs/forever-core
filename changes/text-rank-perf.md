### Fixed

- **Search ranking no longer builds a blanked copy of every title it ranks.** Ranking a name in a search list (Adventure Guide Forever) rebuilt the title with punctuation blanked, and a word list for the query, on every call; it now scans the title's own word starts directly and re-folding an already folded name returns it unchanged, so a long list ranks in about a third of the time at the same tiers.
