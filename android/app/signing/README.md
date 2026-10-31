# Test signing key

`test-signing.jks` signs the test APKs that CI publishes, so every test build
has the same signature and installs as an update over the previous one.

It is public on purpose and only for testing. A store release must use a
separate private upload key kept out of the repository.
