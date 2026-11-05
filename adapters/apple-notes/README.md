# apple-notes adapter

Feeds Apple Notes into `ce`, one source artifact per note (type `apple-note`,
keyed on the Notes identifier). An edited note supersedes its old version.

Input is a normalised SQLite export (`notes` + `folders` tables), not Apple's
`NoteStore.sqlite` itself: decoding Apple's gzip/protobuf bodies is the export
pipeline's job.

    CE_DB=… ce-apple-notes --skip-body 'password|wachtwoord' --db notes.db

`--skip-body` keeps notes that hold secrets out of the store; they are only
counted. Locked and empty notes are left out.
