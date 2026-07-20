-- Blanket-enforcing MFA by role ('admin','cfo') broke every demo/seeded admin
-- account, including the ones this app's own one-click demo login and E2E
-- suite rely on — there's no way to retrieve a real emailed OTP in an
-- automated context. Real IAM systems (Azure AD Conditional Access, Okta)
-- target MFA per-user/per-policy, not by blanket role. Add a real opt-in
-- flag instead; defaults to off so existing/demo accounts are unaffected,
-- and a real admin can enable it for their own account.
alter table public.user_profiles add column if not exists mfa_enabled boolean not null default false;
