Apple Root CA G3 is a public trust anchor downloaded from
https://www.apple.com/certificateauthority/AppleRootCA-G3.cer.

The official Apple App Store Server Library validates the supplied certificate
chain against this root, with online revocation checks enabled. It also validates
the app bundle ID, App Store app ID (production), and receipt environment.
The certificate is explicitly included in Next.js deployment file tracing.
