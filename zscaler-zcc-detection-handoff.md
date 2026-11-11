# Detecting Zscaler Client Connector (ZCC) Status from a Custom iOS App

**Handoff document:** chat export, team briefings, and sample-app spec
**Date:** 2026-11-11

This file has four parts:

1. **[Project context](#1-project-context-short-version)**: a short summary of what we're trying to do (safe to paste into an email or ticket).
2. **[Briefings and questions for each team](#2-briefings-and-questions-by-team)**: Zscaler admins, MDM team and network/security team, each with a short intro.
3. **[Full chat export](#3-full-chat-export)**: every question and answer in order, plus the complete research report.
4. **[Sample "ZCC Lab" app spec](#4-sample-app-spec-zcc-lab)**: the build spec for a diagnostic app to run on a work laptop and a company phone, ready to hand to a coding session.

---

## Table of contents

- [1. Project context (short version)](#1-project-context-short-version)
- [2. Briefings and questions by team](#2-briefings-and-questions-by-team)
  - [2.1 Zscaler admin / support / SE](#21-zscaler-admin--support--se)
  - [2.2 MDM team](#22-mdm-team)
  - [2.3 Network / security team](#23-network--security-team)
  - [2.4 If you can only get a few answers](#24-if-you-can-only-get-a-few-answers)
- [3. Full chat export](#3-full-chat-export)
  - [Q1: What Zscaler product works with the ZSDK?](#q1-what-zscaler-product-works-with-the-zsdk)
  - [Q2: Can ZSDK be used with ZIA and ZPA?](#q2-can-zsdk-be-used-with-zia-and-zpa)
  - [Q3: Purpose of ZSDK in an app vs. ZCC on a company phone](#q3-purpose-of-zsdk-in-an-app-vs-zcc-on-a-company-phone)
  - [Q4: Detecting ZCC status from a custom iOS app (research)](#q4-detecting-zcc-status-from-a-custom-ios-app-research)
  - [Q5: Questions to ask the Zscaler / MDM teams](#q5-questions-to-ask-the-zscaler--mdm-teams)
  - [Q6: This export and the sample app](#q6-this-export-and-the-sample-app)
  - [Appendix A: Full research report](#appendix-a-full-research-report)
- [4. Sample app spec: ZCC Lab](#4-sample-app-spec-zcc-lab)

---

## 1. Project context (short version)

> **What we're doing.** We have an internal iOS app (Swift) that runs on company-owned, MDM-managed iPhones. It fetches data from internal GraphQL endpoints that only work when Zscaler Client Connector (ZCC) is connected. We want the app to show the user whether Zscaler is connected, so they aren't left guessing when data won't load.
>
> **The problem.** iOS doesn't let a third-party app read the state of another app's VPN. `NEVPNManager` and `NEVPNStatusDidChange` only cover VPN configurations our own app owns. We found no documented Zscaler API, SDK, URL-scheme callback, App Group or managed-config feedback key that exposes ZCC's connection state to another app.
>
> **What we're trying.** The most reliable approach we've found is to test the real dependency: an event-driven probe of the GraphQL host. We want to supplement it with local hints (tunnel interfaces, the ZPA synthetic-IP DNS check, and so on) to explain *why* a probe failed. We're building a diagnostic sample app, "ZCC Lab", to run on a work laptop and a company phone so we can see which signals really change in each ZCC state.
>
> **What we need from you.** Answers to the questions below. Several of them decide which approach is viable at all, such as whether the backend is behind ZIA or ZPA, and whether there's an unpublished status channel.

---

## 2. Briefings and questions by team

### 2.1 Zscaler admin / support / SE

**Context to share:**
We're building an in-app indicator for "is ZCC connected?" in an internal iOS app on supervised, MDM-managed company phones. Public docs show MDM parameters flowing *into* ZCC (`strictEnforcement`, `policyToken`, `PAVConnectionSynced`, `SkipInterfaceInstallation`, and so on) but nothing flowing back out. We're also evaluating the Zscaler SDK for Mobile Apps (ZSDK). Our reading of the docs is that ZSDK is a separate ZTNA product with its own cloud, admin portal and App Connectors, and that it reports only its own tunnel state. We want your confirmation, and any supported options we've missed.

**Questions:**

1. Is the GraphQL host a ZPA application segment, ZIA-gated by source IP, or both? This decides which signals mean anything. A ZPA segment makes the synthetic-IP DNS check useful. A ZIA-gated host makes a probe the only reliable option.
2. Is there any supported way for a third-party iOS app to read ZCC's connection state? That could be an API, an SDK, a URL-scheme callback, or an App Group or Keychain share. We found nothing public, but you may have an unpublished option.
3. Does ZCC on iOS write any managed-app-config feedback that an MDM could read? If it does, what are the key names?
4. Is a ZSDK + ZCC deployment on the same device supported, and how do the two interact? Specifically, does ZCC's full tunnel need bypasses for ZSDK's service edges? Would ZSDK's tunnel state tell us anything about ZCC?
5. Is ZSDK licensed separately, and does it need its own App Connectors? If so, we'd be replacing the ZCC dependency rather than detecting it. Is that what you'd recommend for this app?
6. Does ZCC keep the VPN interface up while the user is logged out, or while ZPA needs re-authentication? Does `SkipInterfaceInstallation` change this? It affects how much a "tunnel interface present" check can tell us.
7. How long does ZCC take to rebuild its tunnel after a Wi-Fi/cellular change? That tells us how long to wait before showing "not connected".
8. Does ZCC distinguish "Zscaler disabled" from "Zscaler can't reach the cloud"? Which states should an app expect, and how does each look from the network side?
9. Is the ZCC admin API (`getDevices` and similar) enabled for our tenant, and does it expose a device's enrollment or service status? It's an admin-side view, but it could support a server-side "is this device enrolled" check.
10. Is there a lightweight health or "is Zscaler active" endpoint, reachable only through Zscaler and meant for automated checks? `ip.zscaler.com` is documented for humans, not as an API, so we'd like something we can call from code.

### 2.2 MDM team

**Context to share:**
ZCC is deployed to company-owned, supervised iPhones through MDM. We're building an internal app that needs to show whether ZCC is connected. We can't read ZCC's state directly, so we'd like to use MDM to make the environment more predictable: a per-app VPN rule for our app, managed app config for the probe settings, and a way to install test builds on a few devices.

**Questions:**

1. Can we put our app in a ZCC per-app VPN rule? If so, can we set `PAVConnectionSynced`, so the per-app VPN waits until ZCC is connected?
2. Can we push our own managed app config to the app, such as the probe URL, an expected synthetic-IP range, and feature flags for the heuristics? That keeps undocumented checks switchable without an app release.
3. Does the MDM show live ZCC state, or only "installed" and "VPN profile present"? How stale can that data be?
4. Can the MDM read back managed feedback from our app, so admins can see the last probe result per device?
5. Which VPN payload type deploys ZCC: a "Custom" or "Zscaler" payload, on-demand rules, or Strict Enforcement? Are the devices supervised? This affects behavior when the user isn't logged in.
6. Are there trusted-network rules that deliberately turn ZCC off on corporate Wi-Fi? If so, the app should show "not required here" rather than "disconnected".
7. Can we get a few supervised test devices in different states: logged out, ZPA disabled, ZIA disabled, and on a trusted network? These are needed for the test matrix.
8. **Test-build distribution:** how can we install a diagnostic build on a company phone and a work laptop (development provisioning, internal TestFlight, or an MDM-distributed app)? Can its bundle ID be added to the per-app VPN rule?

### 2.3 Network / security team

**Context to share:**
We want the app to show users a clear "Zscaler connected / not connected / offline" indicator for access to the internal GraphQL service. To do that we'd like to make a small request to the GraphQL host periodically while the app is in the foreground, and to run diagnostic tests (DNS lookup, ping, TCP connect, TLS check) from our test app.

**Questions:**

1. Which Zscaler service sits in front of the GraphQL endpoint, and is there an unauthenticated health route on that host, such as `/healthz`, that is fine to probe every 30–60 seconds?
2. Is it acceptable for the app to call a Zscaler-hosted check page on company devices?
3. Do you want the app to block, warn or just inform the user when Zscaler is off? That sets how conservative the indicator should be.
4. Are ICMP ping and traceroute from a test app acceptable on the corporate network and through ZPA? (ZPA typically doesn't carry ICMP unless configured.)

### 2.4 If you can only get a few answers

1. ZIA vs ZPA path for the GraphQL host.
2. Any hidden or supported status channel from Zscaler.
3. A per-app VPN rule for the app.
4. A health endpoint we can probe.

Together these decide whether the event-driven probe from the research report is enough, or whether something more is needed.

---

## 3. Full chat export

*Source links from the original answers are kept as Markdown links. Where the original answer quoted Zscaler documentation, the same short quotes are kept here.*

---

### Q1: What Zscaler product works with the ZSDK?

**You:** What Zscaler product works with the ZSDK?

**Claude:** The Zscaler component that works with ZSDK is the **App Connector**. Per Zscaler's docs, ZSDK's cloud architecture has three pieces: ZSDK Public Service Edges, App Connectors, and Mobile Client SDK. The App Connectors "provide a secure interface between an organization's back-end services and Zscaler cloud". The docs' setup steps also include configuring a token validator and registering your app to get an app key.

ZSDK is not paired with Zscaler Client Connector (ZCC). ZSDK is "a Zero Trust Network Access (ZTNA) security solution designed for consumer mobile applications". It is "designed for native (iOS or Android) and hybrid mobile applications" and "uses Mutual Transport Layer Security (mTLS) microtunnels to encrypt all network requests originating from the mobile app". The tunnel is built into the app itself, so the device doesn't need a separate client. ZCC, by contrast, is a device-level app that connects users to ZIA and ZPA.

I didn't find a doc that states how ZSDK is licensed or whether it requires a full ZPA subscription. App Connectors are the same component ZPA uses, but ask your Zscaler rep to confirm the licensing and how ZSDK's App Connectors relate to a ZPA tenant.

Sources:
- [What Is Zscaler SDK for Mobile Apps?](https://help.zscaler.com/zsdk/what-zscaler-sdk-mobile-apps)
- [Understanding ZSDK Cloud Architecture](https://help.zscaler.com/zsdk/understanding-zsdk-cloud-architecture)
- [Step-by-Step Configuration Guide for ZSDK](https://help.zscaler.com/zsdk/step-step-configuration-guide-zsdk)
- [What is Zscaler Client Connector?](https://help.zscaler.com/zscaler-client-connector/what-is-zscaler-client-connector)

---

### Q2: Can ZSDK be used with ZIA and ZPA?

**You:** Is it possible to use ZSDK with the ZIA and ZPA?

**Claude:** Probably not in the sense of one integrated stack. Zscaler's docs don't describe ZSDK as plugging into ZIA or ZPA, and what they do describe looks like a separate service.

- **Its own admin portal and cloud.** The configuration guide has you register your app in the ZSDK Admin Portal and deploy App Connectors. Those connectors enroll against the ZSDK cloud: "a TLS client certificate that it must use to authenticate itself to the ZSDK cloud".
- **Its own edges.** ZSDK traffic goes through ZSDK Public Service Edges, not the ZIA or ZPA service edges. "The ZSDK Public Service Edge acts as a broker to route connections via the App Connector's microtunnel."
- **Different scope.** ZSDK is a ZTNA product for your own app's traffic. ZIA is internet and SaaS security, and ZPA is private access, and both are normally reached through Client Connector. Zscaler's help center lists ZSDK as its own product area, separate from ZIA, ZPA and Client Connector.

So the App Connectors mentioned earlier are ZSDK's own, even though they share the name and general architecture with ZPA's. I haven't found documentation saying they can be shared with a ZPA tenant.

I also couldn't confirm a few things from the public docs:
- Whether ZSDK microtunnels coexist cleanly with ZCC on the same device. For example, whether an app using ZSDK also gets its traffic captured by ZCC's ZIA tunnel or ZPA per-app VPN.
- Whether ZSDK is licensed separately or bundled with ZIA or ZPA.
- Whether any policy or logging is shared with ZIA or ZPA.

The Zscaler help pages wouldn't load for me (they need JavaScript), so I only had search excerpts. Your Zscaler rep or SE can answer these directly. The ZSDK "Ranges & Limitations" help page may also cover coexistence.

---

### Q3: Purpose of ZSDK in an app vs. ZCC on a company phone

**You:** what is the purpose for an app using ZSDK? compare that with a company phone using ZCC.

**Claude:** They solve different problems, and the main difference is who controls the device.

**An app using ZSDK**

ZSDK is a ZTNA security solution designed for consumer mobile applications. It's for apps you ship to people whose devices you don't manage, such as customers on the App Store. You embed it in the app itself: ZSDK is embedded into the application's source code during development. It does two things:
- **Secures the app's traffic.** It uses mTLS microtunnels to encrypt all network requests originating from the mobile app, so the app's back end sits behind App Connectors instead of being exposed to the internet.
- **Protects the app.** It does application authentication and integrity verification, using a unique device fingerprint and application signature to prevent unauthorized copies or modifications of protected applications.

The protection travels with the app and needs nothing from the device. It only covers that one app's traffic to your back end.

**A company phone using ZCC**

ZCC is a device-level agent. It forwards the user's traffic to Zscaler: it establishes a lightweight tunnel (called the Z-Tunnel) to the ZIA Public Service Edge, and forwards the user's web traffic through the tunnel so security and access policies can be applied. On mobile it authenticates the user using your corporate authentication mechanism and installs a VPN profile, usually pushed by MDM. With ZPA it also gives access to internal resources. It's included as part of the ZIA and ZPA offerings.

It protects the user and the device across all apps and browsing, and enforces corporate policy.

| | ZSDK | ZCC |
|---|---|---|
| Lives in | Your app's code | Agent on the device |
| Device ownership | Unmanaged, customer-owned | Managed, company-owned |
| Scope | That app's traffic to your back end | All device traffic, including web |
| Identity | App and device integrity | Corporate user via your IdP |
| Typical use | Customer-facing apps | Employee devices |

That split is my reading of the docs rather than something they spell out. If you can mandate ZCC through MDM, as on company phones, you generally don't need ZSDK to reach internal services. ZSDK fits when you can't install anything on the device but still need that app's back-end connection locked down and the app protected from tampering.

---

### Q4: Detecting ZCC status from a custom iOS app (research)

**You:** I am having trouble in a ios Swift app detecting any changes in the ZCC its for a company owned mobile device on MDM. I am just looking for a way to detect if zscaler is connected or not in the zCC app. but the iOS app will be a custom made app also on the device

**Claude:** Started a deep-research task on this. The full report is reproduced in [Appendix A](#appendix-a-full-research-report).

**Headline findings:**

- There is **no supported way** for a third-party iOS app to read ZCC's connection state.
- `NEVPNManager` only reports status for VPN configurations your own app owns, which is why you see no state changes.
- The most reliable indicator is an **active, event-driven probe of the GraphQL host itself**. Local heuristics (ZPA synthetic-IP DNS check, scoped tunnel interfaces) can make the message more precise but should never be the only signal.
- **ZSDK is the wrong tool** for this indicator. It reports its own tunnel, not ZCC's.

---

### Q5: Questions to ask the Zscaler / MDM teams

**You:** what questions could I ask the Zscaler / MDM team to get more options or clarification?

**Claude:** These questions would get you the most from each team. They're grouped by who can answer, with why each one matters. The full question lists, with context blurbs you can paste, are in [Section 2](#2-briefings-and-questions-by-team) of this file.

**Zscaler admin / support / SE**
1. Is the GraphQL host a ZPA application segment, ZIA-gated by source IP, or both? This decides which signals mean anything.
2. Is there any supported way for a third-party iOS app to read ZCC's connection state (API, SDK, URL-scheme callback, App Group or Keychain share)?
3. Does ZCC on iOS write any managed-app-config feedback that an MDM could read?
4. Is a ZSDK + ZCC deployment on the same device supported, and how do the two interact?
5. Is ZSDK licensed separately, and does it need its own App Connectors?
6. Does ZCC keep the VPN interface up while the user is logged out, or while ZPA needs re-authentication? Does `SkipInterfaceInstallation` change this?
7. How long does ZCC take to rebuild its tunnel after a Wi-Fi/cellular change?
8. Does ZCC distinguish "Zscaler disabled" from "Zscaler can't reach the cloud"?
9. Is the ZCC admin API enabled for the tenant, and does it expose enrollment or service status?
10. Is there a lightweight health endpoint meant for automated checks, reachable only through Zscaler?

**MDM team**
1. Can the app go in a ZCC per-app VPN rule, with `PAVConnectionSynced`?
2. Can we push our own managed app config (probe URL, synthetic range, feature flags)?
3. Does the MDM show live ZCC state, or only "installed" and "VPN profile present"?
4. Can the MDM read back managed feedback from our app?
5. Which VPN payload type deploys ZCC, and are the devices supervised?
6. Are there trusted-network rules that deliberately turn ZCC off?
7. Can we get a few supervised test devices in different states?

**Network / security team**
1. Which Zscaler service fronts the GraphQL endpoint, and is there an unauthenticated health route that's fine to probe every 30–60 seconds?
2. Is it acceptable for the app to call a Zscaler-hosted check page?
3. Should the app block, warn or just inform when Zscaler is off?

**If you can only get a few answers:** ZIA vs ZPA path for the GraphQL host; any hidden or supported status channel from Zscaler; a per-app VPN rule for your app; a health endpoint you can probe.

---

### Q6: This export and the sample app

**You:** Can you put this entire chat into an MD file for me. I also want to include some sort of context introduction for the sections for the Zscaler MDM teams etc. That explain in a short way what I am trying to do. I want to switch over to code this into a app. I also want the app to be a sample app with all the options we discussed so I can test on my Work laptop and company phone. It would also be great to have output on the app itself for logs etc so I can test different senarios I am open for ideas. Even a way to hardocode and or put in a URL and do a "NSlookup" or ping and get all the stats what was sent what the response was and what IP address is available etc.

**Claude:** This file. The context blurbs are in [Section 1](#1-project-context-short-version) and [Section 2](#2-briefings-and-questions-by-team), and the build spec for the sample app is in [Section 4](#4-sample-app-spec-zcc-lab).

---

### Appendix A: Full research report

#### Detecting Zscaler Client Connector (ZCC) Status from a Custom iOS App

There is no supported way for a third-party iOS app to read ZCC's connection state. Zscaler documents no API, URL-scheme callback, App Group, shared Keychain or managed-config feedback channel for this, and iOS lets an app query `NEVPNManager` status only for VPN configurations the app owns. The most reliable indicator is an active, event-driven probe of the GraphQL host itself. Local heuristics (a ZPA synthetic-IP DNS check, scoped tunnel interfaces) can make the message more precise, but they should never be the only signal.

##### TL;DR

- **No official channel exists.** Zscaler's iOS MDM parameters only carry configuration into ZCC; nothing documented comes back out. Apple DTS (Quinn "The Eskimo!") confirms that `NEVPNManager` "only works for VPN configurations associated with your app" and that for detecting VPN "there's no single API that returns a direct answer". This is why the developer sees no state changes: `NEVPNStatusDidChange` never fires for ZCC's tunnel inside your app.
- **Test reachability, not VPN presence.** Run a short-timeout `URLSession` probe of the actual GraphQL endpoint whenever `NWPathMonitor` reports a path change, the app returns to the foreground, a real request fails, or a slow timer fires while the app is in the foreground. This is ground truth for what the user cares about ("can I get my data?"). It works whether the backend is reached through ZIA, ZPA or a trusted on-prem network.
- **ZSDK is the wrong tool for this indicator.** It is a separate product with its own cloud (e.g., `zsdkone.net`), admin portal, app key, JWT token validator and App Connectors. It creates an in-app tunnel only for the `URLSession`/`WKWebView` instances you configure, and its `status()` API reports *ZSDK's own* tunnel, not ZCC's. Adopting it would replace the dependency on ZCC rather than detect it, and coexistence with ZCC on the same device is undocumented.

##### Key Findings

| Question | Answer | Evidence level |
|---|---|---|
| Public Zscaler API/SDK for a third-party app to read ZCC state on iOS | None found | Documented by absence: help.zscaler.com, ZCC iOS parameters page, zscaler-sdk-ios README |
| `NEVPNManager` / `NEVPNStatusDidChange` for ZCC's VPN | Not possible. Status is "Invalid" for configurations you don't own | Officially stated by Apple DTS |
| `CFNetworkCopySystemProxySettings()["__SCOPED__"]` / `getifaddrs` utun check | Works as a heuristic, but iOS creates utun interfaces for its own purposes, and ZCC can keep its interface up while it is logged out | Community-known, partly inferred |
| `NWPathMonitor` | Useful as a *trigger* to re-check. Not a ZCC status source | Apple docs + community |
| Probe of internal GraphQL host | Most accurate signal for the app's real dependency | Inferred best practice |
| ZPA synthetic IP (100.64.0.0/16 default) check | Strong ZPA-specific hint if the host is a ZPA application segment | Documented by Zscaler (synthetic IP range); app-side use is inferred |
| ip.zscaler.com | Zscaler's documented manual check for ZIA forwarding. Its page format is not a documented API | Documented for humans, not machines |
| ZCC managed app config / AppConfig feedback | Input-only. No documented feedback keys | Documented by absence |
| ZCC public API (`getDevices`, registration state) | Admin API, availability "limited". Not real-time and not reachable when offline | Documented by Zscaler |
| ZSDK | Separate ZTNA product for in-app tunnels; reports its own state | Documented by Zscaler |

##### Details

###### 1. Does Zscaler expose a supported status mechanism for third-party iOS apps?

**No, as far as public documentation shows.**

- **Managed app configuration is one-way.** Zscaler's "Supported Parameters for Zscaler Client Connector for iOS" page lists only inputs the MDM pushes into ZCC. Examples are `strictEnforcement`, `policyToken`, `excludeList`, the ownership variable, `SkipInterfaceInstallation` ("When enabled, only shows VPN icon in iOS when user is logged into Zscaler Client Connector") and `PAVConnectionSynced` ("Delays Per-app VPN connection until Zscaler Client Connector is connected"). There is no documented `com.apple.feedback.managed` output. Even if ZCC wrote managed feedback, that dictionary lives in ZCC's own `UserDefaults` and is read by the MDM server, not by other apps. Apple's ManagedAppConfig sample describes feedback as data the app "can write … into NSUserDefaults which can then be queried by an MDM server."
- **No App Group, shared Keychain or SDK.** ZCC is signed by Zscaler's team, and your app cannot join Zscaler's App Group or Keychain access group. No ZCC client SDK for iOS is published. The `zscaler/zscaler-sdk-ios` repo is ZSDK (see §5), not a ZCC companion library. Its README only covers integration via SwiftPM, CocoaPods or a manual `.xcframework`.
- **URL scheme.** Apple's own App Store listing for ZCC (Version 3.8.2 notes, dated 01/29/2025) includes a fix for an issue where "the zsa:// shortcut that opens Zscaler Client Connector didn't work." This shows a `zsa://` scheme exists to *open* the app. Nothing indicates it returns status or supports x-callback-url. You could use it for an "Open Zscaler" button: add `zsa` to `LSApplicationQueriesSchemes` if you call `canOpenURL`. This is verified via Apple's App Store release notes, not a Zscaler help page.
- **Zscaler's own status surfaces are admin-side or desktop-only.** ZCC reports ZIA/ZPA health to the Client Connector Portal, and release notes mention "current health and enabled status of … ZIA and … ZPA in the Zscaler Client Connector Portal". The Windows client exposes state in registry keys. Neither of these is available to an iOS app.
- **Zscaler Client Connector public API.** `/papi/public/v1/getDevices`, `getDeviceDetails` and `downloadServiceStatus` return device registration state and service status. However, Zscaler notes "Availability of the Zscaler Client Connector API is limited", the API must be enabled by Zscaler Support, and it requires admin API keys. A backend could call it, but this has three problems: (a) the result is a coarse, delayed fleet view, (b) the API secret must never ship in the app, and (c) when ZCC is down the app usually can't reach that backend anyway. At most it can answer "is this device enrolled".

###### 2. How ZCC's VPN works on iOS, and what your app can observe

**Implementation.** Zscaler's "What Is Zscaler Client Connector?" page says "The device then establishes a local VPN tunnel that captures application traffic and directs it to Zscaler Client Connector on the device." ZCC installs a VPN profile itself, or the MDM pre-deploys one as a "Custom"/"Zscaler" VPN payload. Its App Store notes refer to "iOS packet tunnel network settings", which is consistent with an `NEPacketTunnelProvider`. Supported modes are:
- an Enterprise (system-wide) VPN for ZIA,
- Per-App VPN, and
- a dual tunnel ("per app VPN access for … ZPA apps along with Enterprise VPN for … ZIA").

Zscaler states that "Zscaler Client Connector for iOS does not support Tunnel with Local Proxy", so you shouldn't expect a system HTTP proxy to detect. On-demand rules and Strict Enforcement (which blocks traffic until the user enrolls) may also apply. Strict Enforcement requires supervised, company-owned devices.

**`NEVPNManager` / `NEVPNStatusDidChange`: why you see no changes.** Apple DTS states that this API "only works for VPN configurations associated with your app": your Personal VPN configurations, or configurations for your own NE provider. "You can't check the status of other VPN configurations this way. The API just isn't built to support that case." `NEVPNManager.shared().loadFromPreferences` in your app sees only your app's (nonexistent) configuration, so `connection.status` is `.invalid` and the notification never posts. Adding the Personal VPN entitlement doesn't change this. It is an architectural boundary, not a bug.

**`CFNetworkCopySystemProxySettings()` → `__SCOPED__`.** This undocumented key lists per-interface proxy dictionaries. Community code checks it for `tap`/`tun`/`ppp`/`ipsec`/`utun` keys. In Apple's forum thread on per-app VPN detection, a developer observed a `utun2` entry there while a per-app VPN was active. However:
- `__SCOPED__` is undocumented, so Apple can change it at any time.
- iOS creates its own utun interfaces for iCloud Private Relay, Handoff/AirDrop, Personal Hotspot and similar. One maintained gist deliberately excludes `utun` for this reason.
- ZCC's interface can exist while ZCC is logged out or ZPA needs re-authentication. The existence of the `SkipInterfaceInstallation` parameter implies that by default the VPN interface/icon is present even when the user is *not* logged in.

So "utun present" ≠ "ZCC connected", and "utun present" ≠ "ZCC" (it may be another VPN or a system relay).

**`getifaddrs`.** This has the same issues as `__SCOPED__`, plus multiple stale or system utun interfaces. Apple DTS confirmed on a similar Mac thread that there can be more than one utun "even if VPN is not on".

**`NWPathMonitor`.** VPN tunnels appear as interface type `.other`. `pathUpdateHandler` fires when the path changes (interface added or removed, default route changes). It is a good *wake-up trigger* for re-probing, but:
- It won't fire when ZCC's tunnel stays up and only its upstream (Z-Tunnel to a Public Service Edge or ZPA broker) fails, or when ZCC's internal state changes (e.g., ZPA re-auth required).
- With per-app VPN, what your app's path reflects depends on whether your app is in the per-app rule. I infer this; verify it on a device.

**iOS 17/18/26.** I found no Apple documentation of changes to `__SCOPED__` or to `NEVPNManager` scoping in recent releases. The scoping rule is longstanding and was restated by DTS in 2025. ZCC's own iOS 26 notes mention only an SSO-extension authentication loop fix. Treat any heuristic as something to re-validate on every major iOS release.

**Recommended iOS-side approach.** Apple's archived "Designing for Real-World Networks" guide states that "The SCNetworkReachability API is not intended for use as a preflight mechanism for determining network connectivity. You determine network connectivity by attempting to connect," and Quinn (DTS) advises to "try the request and, if it fails, use reachability help explain the failure", which leads directly to the probe-based design below.

###### 3. Reachability-based detection

**Probe the GraphQL host itself (recommended).** This measures the actual dependency. It is correct whether traffic flows via ZPA (an app segment through App Connectors), ZIA (an internet-facing host restricted to Zscaler egress IPs) or a trusted network where ZCC is intentionally off. A cheap request such as `POST {"query":"{__typename}"}`, or a dedicated unauthenticated `/healthz` on the same host, is enough.

Interpret failures by `URLError` code:
- `.cannotFindHost` / `.dnsLookupFailed` usually means internal DNS isn't being served. With ZPA, ZCC intercepts DNS for app-segment FQDNs, so this strongly suggests ZCC/ZPA is down.
- `.timedOut` / `.cannotConnectToHost` usually means the route is missing or blocked.
- `.notConnectedToInternet` means the device is offline. Show "Offline", not "Zscaler off".
- An HTTP 401/403 still means *reachable*.

Pros: ground truth, works for ZIA and ZPA, no private APIs. Cons:
- One round trip of latency.
- False negatives when the backend itself is down. Mitigate by distinguishing DNS failures from 5xx responses, and optionally pair with the ZPA synthetic-IP hint.
- Battery and network use if you poll aggressively. Probe on events, plus about every 30–60 s only while in the foreground.

**ZPA synthetic-IP hint.** When a FQDN matches a ZPA application segment, ZCC answers DNS with a synthetic IP from the default range `100.64.0.0/16`. Admins can "enter a range between 100.64.0.0/16–100.127.0.0./16", per Zscaler's "Configuring the Zscaler Client Connector Synthetic IP Range", and Zscaler's "What Is Zscaler Client Connector?" page notes that on a conflict "Zscaler changes it to 100.65.0.0/16," with the range possibly running "from 100.64.0.0/16 to 100.83.0.0/16". If `getaddrinfo` for the GraphQL host returns an address in 100.64.0.0/10, ZCC's ZPA module is actively intercepting DNS for it. This is a cheap, local and specific signal. It doesn't prove the broker or App Connector path is healthy, so still probe. It is useless if the host is reached via ZIA or on-prem.

**ip.zscaler.com (ZIA only).** Zscaler documents this as the way to check "if a user's traffic is going to the Zscaler service". The page reports the Zscaler cloud, the Public Service Edge hostname and egress IP. Caveats:
- It is a human-readable page, not an API, so parsing its text is brittle.
- Zscaler warns it "might not recognize IPv6 traffic passing through the Zscaler cloud", and its "Understanding IPv6 Support" page points to a separate checker: "Zscaler's My IP Address service is ipv6.zscaler.com."
- It tells you nothing about ZPA.
- It sends a request to a Zscaler host on every check. That is minor for a company-owned device, but document it.

Use it only if you confirm the backend is ZIA-gated, and match on a marker string you validate on a real device.

**Unknown ZIA/ZPA path.** Because it isn't known whether the backend is reached via ZIA, ZPA or both, the direct host probe is the only approach that is correct in every case. Ask the network team which applies. If it's ZPA, add the synthetic-IP hint. If it's ZIA, ip.zscaler.com is an optional secondary signal.

###### 4. MDM / managed-config options

- **ZCC → MDM → your app:** not realistic. ZCC exposes no documented managed-feedback keys. MDM inventory (Jamf/Intune) can report that ZCC is installed and that the VPN profile is present, but not live tunnel state. Even a posture flag that an MDM pushed into your app's `com.apple.configuration.managed` would be minutes to hours stale, which makes it useless as a connection indicator.
- **Zscaler device posture** (e.g., Jamf detection/risk level, ownership variable) flows *into* ZCC to gate ZIA/ZPA policy. It does not flow out to apps.
- **What MDM *can* usefully do:**
  1. Put your app in a ZCC **per-app VPN** rule. Zscaler documents this for Intune ("For Type of automatic VPN, select Per-app VPN" and associate the app) and for Jamf dual-tunnel setups. Optionally set `PAVConnectionSynced`, which delays the per-app VPN until ZCC is connected. This makes your app's routing deterministic and on-demand.
  2. Push your own managed config to your app, e.g., the probe URL, the expected synthetic-IP range, and whether to show the ip.zscaler.com check. These values then match whatever the network team configured.
  3. Optionally, write your *own* managed feedback (e.g., `lastProbeResult`) so MDM admins can see app-observed connectivity. Support for this varies by MDM.

###### 5. Is ZSDK appropriate?

**Not for this use case.** Your earlier research holds up:
- **Separate product and infrastructure.** Zscaler describes ZSDK infrastructure as "ZSDK Public Service Edges, ZSDK Private Service Edges, App Connectors, and Mobile Client SDK". Setup requires you to "register your mobile app to obtain an app key", "Configure a JSON Web Token validator", deploy App Connectors (recommended in pairs) and define application segments in the "ZSDK Admin Portal". Its cloud is distinct (e.g., `admin.zsdkone.net`). Licensing is separate. I couldn't verify pricing.
- **What it reports.** `ZscalerSDK.sharedInstance().status().tunnelConnectionState` and NSNotifications describe *ZSDK's in-app tunnel*. The Best Practices page says to "Subscribe to ZscalerSDK notifications to monitor changes in the tunnel state". Notification names such as `ZscalerSDKTunnelConnected` appear only in third-party summaries, and ZSDK Platform 2.0 renamed tunnels and notifications, so check the xcframework headers. None of this reports ZCC.
- **Scope.** Traffic is tunneled only for sessions you configure with `configure(sessionConfiguration:)` and `setup(websiteDataStore:)`. It is not a device VPN.
- **Coexistence with ZCC.** Undocumented. With ZCC in full-tunnel mode, ZSDK's connection to its Public Service Edges would itself pass through ZCC/ZIA and might need bypasses. I infer this and could not verify it.
- **When it would make sense.** Only if the organization wants this app's backend access to stop depending on ZCC entirely, which is a re-architecture decided by security and network owners. In that case "Is Zscaler connected?" stops mattering for this app.

##### Recommendations (ranked)

1. **Active probe of the GraphQL host, driven by events.** Triggers: `NWPathMonitor` changes (debounced), `willEnterForeground`, failures of real requests, and a foreground-only timer of about 30–60 s. Show three states: Connected / Not connected (Zscaler likely off) / Offline.
2. **Add local hints for a better message.** Use the ZPA synthetic-IP DNS check (if ZPA) and the `__SCOPED__` tunnel check, purely to explain *why* the probe failed (e.g., "Zscaler appears to be off. Open Zscaler Client Connector"). Never let a hint override a successful probe.
3. **MDM per-app VPN for your app** (plus `PAVConnectionSynced`) so routing is deterministic. Push the probe URL and synthetic range through your own AppConfig.
4. **ip.zscaler.com check** only if the backend is confirmed to be ZIA-gated, as a secondary diagnostic.
5. **"Open Zscaler" button via `zsa://`.** This is a UX nicety, verified only through App Store release notes.
6. **Do not** rely on `NEVPNManager`, the ZCC public API or MDM inventory for live status. **Do not** adopt ZSDK just to get an indicator.

##### Swift sketch: option 1 + 2

```swift
import Foundation
import Network
import UIKit

enum ZscalerIndicator: Equatable {
    case connected            // internal backend reachable
    case zscalerLikelyOff     // online, but internal host unreachable
    case offline              // no network at all
    case checking
}

@MainActor
final class ZscalerStatusMonitor: ObservableObject {
    @Published private(set) var state: ZscalerIndicator = .checking

    private let probeURL: URL                       // e.g. https://graphql.corp.example/graphql
    private let session: URLSession
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "zscaler.status.path")
    private var pollTask: Task<Void, Never>?
    private var probeInFlight = false
    private var lastPathSatisfied = true

    init(probeURL: URL) {
        self.probeURL = probeURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        cfg.waitsForConnectivity = false            // fail fast; we want a verdict
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.lastPathSatisfied = (path.status == .satisfied)
                // Give ZCC a moment to re-establish its tunnel after a network change.
                try? await Task.sleep(for: .seconds(1.5))
                await self.probe()
            }
        }
        pathMonitor.start(queue: monitorQueue)

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.probe() } }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.pollTask?.cancel() } }

        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probe()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    /// Call this from your GraphQL client when a real request fails with a URLError.
    func reportRequestFailure() { Task { await probe() } }

    func probe() async {
        guard !probeInFlight else { return }
        probeInFlight = true
        defer { probeInFlight = false }

        guard lastPathSatisfied else { state = .offline; return }

        var req = URLRequest(url: probeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"query":"{__typename}"}"#.utf8)

        do {
            let (_, resp) = try await session.data(for: req)
            // Any HTTP response (even 401/403) proves the internal host is reachable.
            state = (resp is HTTPURLResponse) ? .connected : .zscalerLikelyOff
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                state = .offline
            default:
                // .cannotFindHost / .dnsLookupFailed / .timedOut / .cannotConnectToHost …
                state = .zscalerLikelyOff
            }
        } catch {
            state = .zscalerLikelyOff
        }
    }
}
```

##### Swift sketch: diagnostic hints (use only to refine the message)

```swift
import Foundation
import Darwin

enum ZscalerHints {
    /// Undocumented `__SCOPED__` key; returns tunnel-like interface names.
    /// utun can be iOS-internal (Private Relay, Handoff…) — treat as weak evidence only.
    static func scopedTunnelInterfaces() -> [String] {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = raw["__SCOPED__"] as? [String: Any] else { return [] }
        let prefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
        return scoped.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
    }

    /// True if `host` resolves into 100.64.0.0/10, which covers ZCC's ZPA synthetic range
    /// (default 100.64.0.0/16, configurable up to 100.127.0.0/16).
    /// Blocking call — run off the main actor.
    static func resolvesToZPASyntheticIP(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            if let sa = ai.pointee.ai_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let ip = UInt32(bigEndian: addr)
                if ip & 0xFFC0_0000 == 0x6440_0000 { return true }   // 100.64.0.0/10
            }
            cursor = ai.pointee.ai_next
        }
        return false
    }
}

// Usage when the probe fails:
// let zpaDNS = await Task.detached { ZscalerHints.resolvesToZPASyntheticIP("graphql.corp.example") }.value
// zpaDNS == true  -> "Zscaler is intercepting DNS but the app path failed (backend or ZPA policy issue)"
// zpaDNS == false -> "Zscaler appears to be off — open Zscaler Client Connector"
```

##### Caveats and what to validate on a real managed device

- **Confirm the path.** Ask the network team whether the GraphQL host is a ZPA application segment, ZIA-gated by source IP, or both, and whether your app is in a per-app VPN rule. This decides which hints are meaningful.
- **Test matrix on a supervised device:**
  - ZCC connected
  - ZCC logged out
  - ZPA disabled (with the password or OTP), ZIA enabled
  - ZIA disabled, ZPA enabled
  - "ZPA re-authentication required"
  - Trusted-network detection (ZCC intentionally off on corporate Wi-Fi)
  - Wi-Fi ↔ cellular handoff
  - Airplane mode
  - iCloud Private Relay on/off

  For each, log `__SCOPED__` keys, `NWPath.availableInterfaces`, the `getaddrinfo` result and the probe outcome.
- **Timing.** ZCC may need a few seconds after a network change to rebuild its tunnel, and its App Store release notes (4.3.x) describe a fixed issue where "after a network change, the DNS IP address was returned from the previous network for a few seconds, causing DNS traffic failure." Debounce and retry once before showing "Not connected".
- **Undocumented surfaces** (`__SCOPED__`, ip.zscaler.com page text, `zsa://`) can change without notice. Keep them behind feature flags pushed via your AppConfig.
- **Not verified:** ZSDK's current iOS notification names after Platform 2.0; any official ZSDK + ZCC coexistence guidance; ZSDK pricing; whether ZCC on iOS 26 changed its interface naming or on-demand behavior.

##### Sources (as listed by the research task)

- Zscaler: [Supported Parameters for Zscaler Client Connector for iOS](https://help.zscaler.com/zscaler-client-connector/supported-parameters-zscaler-client-connector-ios)
- Zscaler: [What Is Zscaler Client Connector?](https://help.zscaler.com/zscaler-client-connector/what-is-zscaler-client-connector)
- Zscaler: [Verifying a user's traffic is being forwarded to the Zscaler service](https://help.zscaler.com/zia/verifying-users-traffic-being-forwarded-zscaler-service)
- Zscaler: [ZCC and VPN client interoperability best practices](https://help.zscaler.com/zscaler-client-connector/best-practices-zscaler-client-connector-and-vpn-client-interoperability)
- Zscaler: [Deploying ZCC with Microsoft Intune (iOS)](https://help.zscaler.com/zscaler-client-connector/deploying-zscaler-client-connector-microsoft-intune-ios)
- Zscaler: [Deploying ZCC with Workspace ONE UEM (iOS)](https://help.zscaler.com/zscaler-client-connector/deploying-zscaler-client-connector-workspace-one-uem-ios)
- Zscaler: [Zscaler + Jamf deployment guide (PDF)](https://help.zscaler.com/downloads/zscaler-technology-partners/endpoint/zscaler-and-jamf-deployment-guide/Zscaler-Jamf-Deployment-Guide-FINAL.pdf)
- Zscaler: [Configuring device posture profiles (ZPA)](https://help.zscaler.com/zscaler-client-connector/configuring-device-posture-profiles-zpa)
- Zscaler: [ZCC registry keys](https://help.zscaler.com/z-app/zscaler-app-registry-keys)
- Zscaler: [Client Connector public API controller](https://help.zscaler.com/client-connector/public-api-controller?pageSize=2024)
- Zscaler: [Getting started with the Client Connector API](https://help.zscaler.com/legacy-apis/getting-started-client-connector-api)
- Zscaler: [Understanding the Zscaler Client Connector API](https://help.zscaler.com/client-connector/understanding-zscaler-client-connector-api)
- Zscaler: [ZCC app release summary 2024 (iOS)](https://help.zscaler.com/client-connector/client-connector-app-release-summary-2024?applicable_category=iOS&applicable_version=3.8)
- Zscaler ZSDK: [cloud architecture](https://help.zscaler.com/zsdk/understanding-zsdk-cloud-architecture), [cloud name](https://help.zscaler.com/zsdk/what-my-cloud-name-zsdk), [configuration guide](https://help.zscaler.com/zsdk/step-step-configuration-guide-zsdk), [best practices](https://help.zscaler.com/zsdk/best-practices), [iOS integration guide](https://help.zscaler.com/zsdk/zsdk-integration-guide-ios), [platform release summary 2025](https://help.zscaler.com/zsdk/zsdk-platform-release-upgrade-summary-2025)
- GitHub: [zscaler/zscaler-sdk-ios](https://github.com/zscaler/zscaler-sdk-ios)
- Zscaler community: [ZPA DNS routing](https://zscaler.zscaler.az-ap.com/article/18/zpa-dns-routing) (listed as `https://zscaler.az-ap.com/article/18/zpa-dns-routing`)
- Apple: [ManagedAppConfig sample](https://developer.apple.com/library/archive/samplecode/sc2279/introduction/intro.html), [ManagedAppConfig view controller listing](https://developer.apple.com/library/archive/samplecode/sc2279/Listings/ManagedAppConfig_APLViewController_m.html)
- Apple Developer Forums: [786814](https://developer.apple.com/forums/thread/786814), [696533](https://developer.apple.com/forums/thread/696533), [682767](https://developer.apple.com/forums/thread/682767), [671678](https://developer.apple.com/forums/thread/671678); [Apple Support thread 255645034](https://discussions.apple.com/thread/255645034)
- App Store: [ZCC listing (US)](https://apps.apple.com/us/app/zscaler-client-connector/id1216875274), [(SA)](https://apps.apple.com/sa/app/zscaler-client-connector/id1216875274), [(GB)](https://apps.apple.com/gb/app/zscaler-client-connector/id1216875274)
- Community: [VPN detection gist](https://gist.github.com/m1guelpf/aaa27bde09584b1c5a9ac236de1c8964), [VPN network detection in iOS (Medium)](https://medium.com/@rishabhkochar27/vpn-network-detection-in-ios-a-deep-dive-into-technical-foundations-apis-and-best-practices-1c4600f98549), [VPN detection guide (Tarkalabs)](https://tarkalabs.com/blogs/vpn-detection-guide-ios-android/), [Deploy Zscaler to iOS](https://simongoltz.com/deploy-zscaler-to-ios/), [Deploy ZApp Mobile with Intune](https://nathancatania.com/posts/deploy-zapp-mobile-with-intune/), [App configuration](https://solarana.dev/2020/12/30/app-configuration/), [AppConfig ManagedAppConfig PDF](https://www.appconfig.org/assets/images/appconfig-media/appconfig-content/uploads/2017/01/ManagedAppConfig.pdf), [zscaler-skill issue 316](https://github.com/dvmrry/zscaler-skill/issues/316)

---

## 4. Sample app spec: ZCC Lab

A diagnostic app that implements **every detection option from the research** side by side, plus network tools and an in-app log, so you can flip ZCC between states on a real company phone and work laptop and see which signals actually change.

> **How to use this section.** Open this file in a coding session on your Mac (for example Claude Code with Xcode installed) and ask it to scaffold the project from this spec. Build and run on a real device. The simulator has no ZCC, so it only validates UI and the network tools.

### 4.1 Goals

1. Show, for any moment in time, what **every** candidate signal reports, side by side, so you can see which ones track ZCC's real state.
2. Give a clear **combined verdict** (Connected / Not connected / Offline / Unknown) with the reasons behind it, while always keeping the raw signals visible.
3. Provide **network tools** (DNS lookup, ping, TCP connect, HTTP probe with full timing, traceroute, TLS inspection) against hardcoded or user-entered targets, showing exactly what was sent, what came back, and which IP was used.
4. Record everything in a persistent, searchable, exportable **in-app log**, plus **scenario snapshots** you can label ("ZCC logged out", "ZPA disabled") and compare.

### 4.2 Platforms and tech

- **Targets:** iOS 17+ (company phone) and macOS 14+ (work laptop), one multiplatform SwiftUI app with a shared core and small platform-specific sections.
- Swift 6 with structured concurrency; SwiftUI; Swift Charts for timelines; no third-party dependencies.
- Frameworks: `Network` (NWPathMonitor, NWConnection), `NetworkExtension` (NEVPNManager, to demonstrate it doesn't work for ZCC), `CFNetwork`, `Darwin` (getifaddrs, getaddrinfo, sockets), `Security` (certificate inspection), `os` (Logger).
- **Not sandbox-limited on macOS for debug builds** so the laptop version can run `Process`-based commands (see 4.6). Keep those behind `#if os(macOS)`.

### 4.3 Screens

| Tab | Purpose |
|---|---|
| **Dashboard** | Combined verdict plus a live table of every signal, with last-changed time. Buttons for "Probe now", "Capture snapshot" and "Open Zscaler (`zsa://`)". |
| **Tools** | DNS lookup, Ping, TCP connect, HTTP probe, Traceroute, TLS inspect. Target field with presets. |
| **Environment** | Interfaces (getifaddrs), full proxy settings dump, DNS resolver info, current NWPath details, managed app config contents, device and OS info. |
| **Scenarios** | Label and capture snapshots, view the test-matrix checklist, compare two snapshots (diff), export. |
| **Timeline** | Chart of signal values over time, with markers when you flipped ZCC state. |
| **Logs** | Live console with level and category filters, search, copy, share/export (Markdown and JSONL). |
| **Settings** | Hardcoded defaults, editable targets, probe interval, feature flags, "Reset to managed config". |

### 4.4 Detection signals (everything we discussed)

Each signal is a small module with a common interface: `name`, `explanation`, `run() async -> SignalResult` (value, raw detail, duration, timestamp). The Dashboard shows them all.

| # | Signal | What it does | Expected behavior (to verify) |
|---|---|---|---|
| A | **NEVPNManager status** | `loadFromPreferences`, read `connection.status` | `.invalid` for ZCC's VPN. Included to *demonstrate* the limitation. |
| B | **NEVPNStatusDidChange observer** | Observe and log every notification | Never fires for ZCC. Log "0 events received" with a counter. |
| C | **Proxy `__SCOPED__` keys** | `CFNetworkCopySystemProxySettings()`, list tunnel-like keys (`utun*`, `ipsec*`, `ppp*`, `tun*`, `tap*`) | Weak evidence. Compare with ZCC on/off. |
| D | **getifaddrs interfaces** | List all interfaces with flags and addresses, highlight `utun*` | Same caveats. Shows whether ZCC's interface stays up when logged out. |
| E | **NWPathMonitor** | Log every path update: status, interface types, available interfaces, `isExpensive`, `isConstrained`, `supportsDNS`, `supportsIPv4/6` | Trigger only. Log whether it fires when ZCC changes state. |
| F | **GraphQL probe** | POST `{__typename}` (or GET a health route) with a short timeout. Classify by `URLError` code or HTTP status. | The primary signal. |
| G | **ZPA synthetic IP check** | `getaddrinfo` for each target host; flag any answer in 100.64.0.0/10 | Only meaningful if the host is a ZPA segment. |
| H | **ip.zscaler.com check** | GET the page, show the raw body, and test for a configurable marker string | ZIA only. Verify the marker on a real device. |
| I | **`zsa://` scheme** | `canOpenURL` (needs `LSApplicationQueriesSchemes`), plus a button that opens ZCC | UX nicety only. |
| J | **Managed app config** | Read `UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")`, show it, and listen for `UserDefaults.didChangeNotification` | Shows what MDM pushed. Also use it to override settings. |
| K | **Managed feedback write** | Write the last verdict to `com.apple.feedback.managed` | Test whether the MDM can read it back. |
| L | **ZSDK status (optional, off by default)** | Behind a build flag, show `status().tunnelConnectionState` if you ever add the SDK | Reports ZSDK's own tunnel, not ZCC. |
| M | **macOS only: system checks** | `scutil --nc list`, `scutil --proxy`, `scutil --dns`, `ifconfig`, and a check for a running Zscaler process via `NSWorkspace.shared.runningApplications` | The laptop can see far more than iOS. Useful as ground truth while testing. |

**Combined verdict rules (initial):**

- Path unsatisfied → **Offline**.
- Probe (F) succeeded with any HTTP response → **Connected**, regardless of other signals.
- Probe failed with DNS error → **Not connected (DNS)**. If G says "no synthetic IP", add the hint "Zscaler appears to be off".
- Probe failed with timeout or connect error → **Not connected (route)**.
- Always show the raw signal table. The verdict is advisory.
- Retry once after about 2 seconds before showing "Not connected" (ZCC can take a few seconds to rebuild its tunnel after a network change).

### 4.5 Network tools (what you asked for)

All tools take a hostname or URL, with presets (hardcoded list in Settings) and a free-text field. Every run writes a full record to the log.

**DNS lookup (nslookup-style)**
- `getaddrinfo` for A and AAAA, showing **every** returned address, canonical name, and duration.
- Optional record types (A, AAAA, CNAME, MX, TXT, SRV, PTR) via `DNSServiceQueryRecord` (dnssd).
- Show the resolvers in use (via `res_9_ninit` / `res_9_getservers`, and `scutil --dns` on macOS).
- Flag results in 100.64.0.0/10 as "ZPA synthetic IP?" and show the resolver that answered, if available.
- Compare "system resolver" answers vs. a direct query to a chosen DNS server (to see what ZCC intercepts).

**Ping (ICMP)**
- Unprivileged ICMP via `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` (works on iOS and macOS without root).
- Configurable count, interval, payload size and TTL.
- Output per packet: sequence, bytes, source IP, TTL, RTT. Summary: sent, received, loss %, min/avg/max/stddev.
- Note in the UI that ZPA doesn't carry ICMP by default, so a failed ping to a ZPA app doesn't mean the app is down.

**TCP connect**
- `NWConnection` to host:port with state-change logging, connect time, local and remote endpoints, and the path used.

**HTTP probe**
- `URLSession` with `URLSessionTaskMetrics`, shown as a table: DNS time, TCP connect, TLS handshake, request start, time to first byte, response time, total.
- Also show: negotiated protocol (h2/h3), remote IP and port, local IP and port, whether a proxy was used, TLS version and cipher, request headers sent, request body, response status and headers, and body size and preview.
- Method, headers and body are editable, with presets for the GraphQL `{__typename}` request.
- Toggle between a normal session and one with a custom config (no cache, no cookies, `waitsForConnectivity` off, timeouts).

**Traceroute**
- ICMP or UDP with an incrementing TTL (`setsockopt` `IP_TTL`), up to 30 hops, showing each hop's IP, reverse DNS (optional) and RTT. This reveals whether traffic goes through ZCC's tunnel or straight out.
- Mark it clearly as best-effort: ZPA and Zscaler edges commonly don't return TTL-exceeded messages.

**TLS inspect**
- Connect to a host and show the certificate chain (subject, issuer, validity, SANs, SHA-256 fingerprints).
- *Idea:* with ZIA SSL inspection on, a public site's issuer will be Zscaler's CA instead of the real one. Comparing a public site's chain with ZCC on and off could be a strong ZIA signal. **Validate this on a real device before relying on it**, because SSL-inspection bypass lists vary.

**Public IP / egress check**
- GET a configurable "what's my IP" endpoint (and `ip.zscaler.com`) and show the response. Compare the egress IP with ZCC on and off.

### 4.6 macOS-specific extras (work laptop)

Behind `#if os(macOS)` and a debug-only entitlement setup (sandbox off or the relevant exceptions):

- Run and capture `scutil --nc list`, `scutil --proxy`, `scutil --dns`, `ifconfig`, `netstat -rn`, `networksetup -listallnetworkservices`, `nslookup`, `dig`, `/sbin/ping`, and `traceroute`. Show stdout and stderr in the UI and the log.
- Check for running Zscaler processes and the ZCC app via `NSWorkspace`.
- Look for ZCC's log directory and show recent lines read-only, if the path is accessible. Verify the location yourself; don't hardcode it blindly.
- Treat these as **ground truth** to compare against the sandbox-safe signals A–H.

### 4.7 Logging

- `LogEntry`: timestamp (ISO 8601 with ms), category (signal, tool, path, mdm, ui), level, message, and an optional structured payload (JSON).
- In-memory ring buffer (for example 5,000 entries) plus an on-disk JSONL file that rotates by size.
- Console UI: auto-scroll, pause, filter by category and level, text search, tap to expand the payload, copy, and share.
- Export: **Markdown report** (summary, environment, signal table, recent log, tool outputs) and **JSONL**. The Markdown report is meant to be pasted into a ticket for the Zscaler or MDM teams.
- Mirror to `os.Logger` so Console.app and `log stream` work on a tethered Mac.

### 4.8 Scenario recorder

- **Capture snapshot:** runs all signals and tools once, stores one JSON document with a label, timestamp, device info, iOS/macOS version, and ZCC state notes you type in.
- **Auto-capture on change:** optionally snapshot whenever NWPath changes, the app foregrounds, or the verdict changes.
- **Test-matrix checklist** (tap through as you flip states on the device):
  - ZCC connected
  - ZCC logged out
  - ZPA disabled, ZIA enabled
  - ZIA disabled, ZPA enabled
  - ZPA re-authentication required
  - Trusted network (ZCC intentionally off)
  - Wi-Fi ↔ cellular handoff
  - Airplane mode
  - iCloud Private Relay on/off
  - App in or out of the per-app VPN rule
- **Compare:** pick two snapshots and show a diff of which signals changed. This is the main output: which signals actually track ZCC's state.
- **Timeline:** Swift Charts view plotting each signal's value over time, with your scenario labels as markers.

### 4.9 Configuration

- **Hardcoded defaults** in one `Defaults.swift`: GraphQL URL, health route, list of hosts, ZPA synthetic range (default 100.64.0.0/10), ip.zscaler.com marker string, probe interval (45 s), timeouts, and DNS servers to compare against.
- **Editable in Settings**, persisted locally.
- **Overridable via managed app config** (`com.apple.configuration.managed`), so the MDM team can push values without a new build. Suggested keys: `probeURL`, `hosts` (array), `syntheticRange`, `zscalerMarker`, `probeIntervalSeconds`, `enableZscalerPageCheck`.

### 4.10 Project setup notes

- **Info.plist:** `LSApplicationQueriesSchemes` containing `zsa`. `NSLocalNetworkUsageDescription` if you test local addresses. ATS exceptions only for test targets that are plain HTTP, and keep them scoped.
- **Capabilities:** Network Extensions is *not* required to read your own (nonexistent) VPN status. Personal VPN adds nothing for ZCC detection. Don't add entitlements you don't need, because they can complicate provisioning on a managed device.
- **Distribution to a managed phone and laptop:** coordinate with the MDM team. Options are development provisioning on a registered device, internal TestFlight, or an MDM-distributed build. Ask them to add the bundle ID to the per-app VPN rule when you're ready to test that scenario (see MDM question 8).
- **Suggested layout:**
  - `Core/Signals/` (A–M, each its own file)
  - `Core/Tools/` (DNS, Ping, TCP, HTTP, Traceroute, TLS, EgressIP)
  - `Core/Verdict.swift`
  - `Core/Logging/`
  - `Core/Scenarios/`
  - `Core/Config/` (Defaults, ManagedConfig)
  - `UI/` (one folder per tab)
  - `Platform/macOS/` (Process-based checks)
- Start from the two Swift sketches in Appendix A and extend them. They already implement signals F and G.

### 4.11 Ideas to consider beyond what was asked

- **Soak test:** run the probe every few seconds for an hour while you flip ZCC states, then use the Timeline to see response latency and which signal reacted first.
- **Compare resolvers:** query the same internal hostname via the system resolver and via a public DNS server. If only the system resolver answers (with a synthetic IP), ZCC's ZPA DNS interception is working.
- **Per-interface probing:** use `NWParameters.requiredInterfaceType` (`.wifi`, `.cellular`) to test whether the cellular path behaves differently from Wi-Fi.
- **Share sheet "support bundle":** one tap to export the Markdown report and snapshots for the Zscaler or MDM teams.
- **Background refresh test:** check what the probe reports after the app has been backgrounded and resumed, since ZCC may re-establish its tunnel in between.
- **Strict Enforcement behavior:** capture what a probe looks like while ZCC is enrolled-but-blocked, versus not enrolled.
- **Latency budget view:** show DNS/connect/TLS/TTFB for the GraphQL probe over time, to catch "Zscaler connected but slow" separately from "not connected".
- **Result classification table:** show each `URLError` code you saw and how the verdict logic classified it, so you can refine the rules from real data.

### 4.12 Out of scope (on purpose)

- Reading ZCC state through private APIs or by scraping ZCC's UI.
- Shipping the ZCC admin API secret in the app. A backend could use it, but only for coarse fleet-level status.
- Adopting ZSDK just to get an indicator. It would replace the ZCC dependency rather than detect it.
