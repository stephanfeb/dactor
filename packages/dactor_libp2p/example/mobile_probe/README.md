# mobile_probe

Checks `dactor_libp2p` from phones, through the public Ricochet relay that SpiffyVault uses (`ricochet.spiffyvault.net`).

Every probe, phone or laptop, is a dactor node that reserves a slot on the relay, exposes an actor `probe`, and joins process group `probe`. When a member appears, a probe checks it: an ask and its round trip, 5,000 ordered messages, 1 MiB, and an ask back. It watches every member and logs how each connection goes up and down. Phones also log when the app goes to the background and comes back, and check every member again on return.

The phones are given only the laptop's reference. They find each other through the group, which passes on their relay addresses, so the run also tests discovery.

## Run

```sh
# The laptop: a fixed identity, kept in the state file.
dart run bin/peer.dart .probe_state
# It writes its reference to probe_uri.txt. Build the phones with it:
flutter run --release -d <device> --dart-define=PROBE_SEED="$(cat probe_uri.txt)"
```

The phones report what they see to the laptop, which prints it all. `bin/peer.dart --label=x --seed="$(cat probe_uri.txt)" --check` runs another laptop node that joins as a phone would, for trying it without phones.

Release builds, so the app can be killed and started again from the home screen.
