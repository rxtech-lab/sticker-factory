const effectiveDate = "August 27, 2026";

export const privacyPolicyMarkdown = `# Privacy Policy

*Effective date: ${effectiveDate}*

Sticker Factory is provided by RxLab. This policy explains how Sticker Factory handles information when you use the iPhone, iPad, Messages, and web experiences.

## Information we process

- **Account information.** We receive the account identifier, name, email address, and profile image made available by your RxLab sign-in.
- **Sticker content.** We process prompts, uploaded photos and masks, chat messages, project settings, generated stickers, revisions, and exports needed to provide the service.
- **Service information.** We process request, device, and diagnostic information needed to operate, secure, and troubleshoot Sticker Factory.

## How we use information

We use this information to authenticate you, generate and edit stickers, keep your private library in sync, export stickers, prevent abuse, and maintain the service. Sticker content may be sent to AI and infrastructure providers only as needed to fulfill your request and operate Sticker Factory.

## Storage and retention

Sticker projects are private to your account. Project records and chat history are stored in the service database, while uploaded and generated media are stored in private object storage. Deleting a project starts deletion of its project records and private media. Some limited information may be retained when required for security, legal compliance, or resolving abuse.

The app stores sign-in credentials and cached stickers on your device and in its shared app group so the main app and Messages extension can work together. Signing out removes those shared credentials and cached iMessage stickers from the device.

## Sharing

We do not make your sticker projects public by default. We may disclose information to service providers that process it for Sticker Factory, when you direct us to share or export content, or when disclosure is required to protect users, RxLab, or comply with law.

## Your choices

You can choose which photos to upload, delete individual sticker projects, and sign out at any time. You may also use the applicable RxLab account controls for your signed-in information.

## Changes and questions

We may update this policy as Sticker Factory changes. The effective date above identifies the current version. For privacy questions or requests, contact RxLab support.
`;

export const termsOfServiceMarkdown = `# Terms of Service

*Effective date: ${effectiveDate}*

These Terms govern your use of Sticker Factory, a service provided by RxLab. By using Sticker Factory, you agree to these Terms.

## Your account

Use your own RxLab account and keep access to your account and devices secure. You are responsible for activity performed through your account and for providing accurate account information.

## Your content

You keep any rights you hold in prompts, photos, masks, and other content you submit. You give RxLab permission to host, process, reproduce, and transform that content only as needed to operate, secure, and improve Sticker Factory and to fulfill your requests.

You are responsible for ensuring that you have the rights and permissions needed for content you upload and for how you use or share generated stickers.

## Acceptable use

Do not use Sticker Factory to:

- violate law or another person's rights;
- create, upload, or distribute harmful, deceptive, abusive, or illegal content;
- probe, disrupt, overload, or bypass the service's security or access controls;
- automate access in a way that harms the service or other users; or
- represent AI-generated output as guaranteed to be accurate or original.

## AI-generated output

Sticker output is generated automatically and may be inaccurate, unexpected, or similar to content generated for others. Review output before using or sharing it. RxLab does not guarantee that output is unique or suitable for a particular purpose.

## Service changes

We may add, change, suspend, or discontinue features. We may limit or suspend access when reasonably necessary to protect the service, comply with law, or address a violation of these Terms.

## Disclaimers

Sticker Factory is provided on an “as is” and “as available” basis to the extent permitted by law. RxLab does not promise uninterrupted availability or that generated content will meet every requirement.

## Liability

To the extent permitted by law, RxLab is not responsible for indirect, incidental, special, consequential, or punitive damages, or for loss of data, profits, or business arising from your use of Sticker Factory. Rights that cannot legally be limited remain unaffected.

## Changes and questions

We may update these Terms as the service changes. Continued use after updated Terms take effect means you accept the revised Terms. The effective date above identifies the current version. Contact RxLab support with questions about these Terms.
`;

export function markdownDocumentResponse(
  markdown: string,
  cacheControl = "public, max-age=3600, stale-while-revalidate=86400",
): Response {
  return new Response(markdown, {
    headers: {
      "cache-control": cacheControl,
      "content-language": "en",
      "content-type": "text/markdown; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}
