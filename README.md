# Jira automation scripts

Shell scripts for routine Jira project maintenance.

## Scripts

| Script | Description |
| --- | --- |
| `move_quartal.sh` | Finds all epics for a requested `YYQq` quarter, creates or reuses their next-quarter equivalents, and moves every non-completed issue to the target epics. |

## Requirements

- Bash
- `curl`
- `jq`
- Network access to Jira
- A Jira account that can browse the project, create epics, and edit the Epic
  Link/parent field on its issues

Install `jq` on macOS with Homebrew if necessary:

```bash
brew install jq
```

Make the scripts executable after copying them to another machine:

```bash
chmod +x move_quartal.sh
```

## How to get and configure your Jira token

The script supports two authentication methods. Use the one appropriate for
your Jira deployment. Do not put a real token into this repository or commit it
to a `.env` file.

You are normally using **Jira Cloud** when the address ends with
`.atlassian.net`. A Jira installation hosted on your company's own domain is
usually **Jira Data Center**. If you are unsure, ask your Jira administrator
before creating a token.

### Jira Cloud: email and API token

1. Sign in to the Atlassian account that has access to the Jira project.
2. Open [Atlassian account API tokens](https://id.atlassian.com/manage-profile/security/api-tokens).
3. Select **Create API token**.
4. Give it a descriptive name, such as `jira-quarter-rollover`, and choose an
   expiration date.
5. Create and copy the token. Atlassian displays it only once, so store it in a
   password manager.
6. Set the Jira URL and your account email:

```bash
export JIRA_URL='https://your-company.atlassian.net'
export JIRA_USER='your.name@example.com'
```

7. Read the token without placing it in shell history:

```bash
read -rsp 'Jira API token: ' JIRA_API_TOKEN && echo
export JIRA_API_TOKEN
```

The script sends the email and API token using HTTP Basic authentication. It
does not use your Atlassian password.

Verify that the token works and can access Jira:

```bash
curl --fail --silent --show-error \
  --user "$JIRA_USER:$JIRA_API_TOKEN" \
  --header 'Accept: application/json' \
  "$JIRA_URL/rest/api/2/myself" | jq '{accountId, displayName, emailAddress}'
```

The command should print your Jira account information. An HTTP `401` means
that the email or token is invalid; an HTTP `403` normally means that the
account or token is not allowed to access that Jira resource.

See Atlassian's [API-token management guide](https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/)
for expiration, revocation, and scoped-token details.

Atlassian also offers scoped API tokens. Those tokens use an
`https://api.atlassian.com/ex/jira/<cloud-id>` base URL instead of the normal
site URL. If your organization requires scoped tokens, set that complete base
URL as `JIRA_URL` and grant the token the Jira read/write scopes required to
search, create, and edit issues.

### Jira Data Center: personal access token

[Personal access tokens](https://confluence.atlassian.com/enterprise/using-personal-access-tokens-1026032365.html)
are available in supported Jira Data Center releases:

1. Sign in to Jira.
2. Select your avatar, then **Profile**.
3. Select **Personal access tokens** in the left menu.
4. Select **Create token**.
5. Name the token, optionally set an expiry, and create it.
6. Copy the token before closing the dialog.
7. Set the Jira URL:

```bash
export JIRA_URL='https://jira.your-company.example'
```

8. Read and export the token without placing it in shell history:

```bash
read -rsp 'Jira personal access token: ' JIRA_TOKEN && echo
export JIRA_TOKEN
```

The script sends `JIRA_TOKEN` as an `Authorization: Bearer ...` header.

Verify that the token works and can access Jira:

```bash
curl --fail --silent --show-error \
  --header "Authorization: Bearer $JIRA_TOKEN" \
  --header 'Accept: application/json' \
  "$JIRA_URL/rest/api/2/myself" | jq '{name, displayName, emailAddress}'
```

The command should print your Jira account information. If it returns HTTP
`401`, recreate the token or confirm that it has not expired. If it returns
HTTP `403`, ask the Jira administrator to check the account's permissions.

If **Personal access tokens** is absent from your Jira profile, ask the Jira
administrator whether PATs are enabled and which authentication method is
approved for scripts.

### How to use `JIRA_TOKEN`

`JIRA_TOKEN` is intended for a Jira Data Center personal access token. The
script reads it from the environment and sends it as a Bearer token. Do not add
the token to `move_quartal.sh` itself.

Set the Jira address, enter the token without displaying it, and export it:

```bash
export JIRA_URL='https://jira.your-company.example'
read -rsp 'Jira personal access token: ' JIRA_TOKEN && echo
export JIRA_TOKEN
```

Confirm that both variables are available without printing the secret:

```bash
test -n "$JIRA_URL" && echo 'JIRA_URL is set'
test -n "$JIRA_TOKEN" && echo 'JIRA_TOKEN is set'
```

Preview a quartal migration:

```bash
./move_quartal.sh --project-key NSSF --quartal 26Q4 --dry-run
```

Apply it after checking the preview:

```bash
./move_quartal.sh --project-key NSSF --quartal 26Q4
```

The exported token remains available to commands started from the same shell.
Remove it from that shell when finished:

```bash
unset JIRA_TOKEN
```

For a non-interactive environment such as CI, configure `JIRA_TOKEN` as a
masked secret in the CI system and expose it to the script as an environment
variable. Do not place the literal token in the command, repository, or CI
configuration file.

Jira Cloud API tokens use `JIRA_USER` together with `JIRA_API_TOKEN`; they
should not normally be assigned to `JIRA_TOKEN`.

## `move_quartal.sh`

### What it does

For the project passed through `-pk` or `--project-key` and the quarter passed
through `-q` or `--quartal`, the script:

1. Validates the requested `YYQq` value. It must use two year digits, an
   uppercase `Q`, and a quarter from 1 to 4, for example `26Q4`.
2. Gets all project epics and selects every epic whose summary contains that
   requested quarter.
3. Builds the target summary by incrementing the quarter. Rollover from `26Q4`
   produces `27Q1`.
4. Checks whether an epic with that exact target summary already exists. If it
   does, the script reuses it; otherwise, it creates the new epic.
5. Finds direct issues in each source epic whose Jira status category is not
   `Done` and whose lowercase status is neither `ready for test` nor
   `ready to check` nor `ready to install`.
6. Sets their Epic Link (or Jira Cloud parent field) to the matching new epic.

For example:

```text
Payments 26Q4       -> Payments 27Q1
Observability 26Q4  -> Observability 27Q1
```

An issue is considered completed based on Jira's `Done` status category, not a
hard-coded status name. Custom statuses such as `Closed` or `Resolved` are left
in the old epic when Jira assigns them to the `Done` category. Issues in
`Ready for Test`, `Ready to check`, or `Ready to install` are also always left
in the old epic; the JQL comparison uses their lowercase names.

### Preview changes

Always start with a dry run. It performs the searches and prints the planned
epic creations and issue moves, but sends no create or update requests:

```bash
./move_quartal.sh --project-key NSSF --quartal 26Q4 --dry-run
```

Review the requested source quarter, target summaries, existing target epics,
and issue keys.

### Apply changes

After reviewing the dry run:

```bash
./move_quartal.sh --project-key NSSF --quartal 26Q4
```

The short form is equivalent:

```bash
./move_quartal.sh -pk NSSF -q 26Q4
```

The project key and quartal are both mandatory. Invalid or missing values stop
the script before it contacts Jira.

### Configuration

| Environment variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `JIRA_URL` | Yes | — | Jira base URL, without `/rest/api/...` |
| `JIRA_TOKEN` | One auth method | — | Jira Data Center bearer/PAT token |
| `JIRA_USER` | One auth method | — | Jira Cloud Atlassian account email |
| `JIRA_API_TOKEN` | One auth method | — | Jira Cloud API token |
| `JIRA_API_VERSION` | No | `2` | Jira REST API version |
| `JIRA_EPIC_ISSUE_TYPE` | No | `Epic` | Epic issue type name in Jira |
| `JIRA_EPIC_FIELD` | No | Auto-detected | Epic Link field id, such as `customfield_10014` |
| `JIRA_EPIC_NAME_FIELD` | No | Auto-detected | Epic Name field id, such as `customfield_10011` |
| `JIRA_PAGE_SIZE` | No | `100` | Issues requested per search page |
| `JIRA_CACERT` | No | System trust store | CA bundle for an internal Jira certificate |
| `JIRA_INSECURE` | No | `0` | Set to `1` to skip TLS verification; avoid outside temporary diagnostics |

If both authentication methods are set, `JIRA_TOKEN` takes precedence.

Most Jira installations require no field configuration because the script
discovers Epic Link and Epic Name through the Jira field API. To override the
detected values:

```bash
export JIRA_EPIC_FIELD='customfield_10014'
export JIRA_EPIC_NAME_FIELD='customfield_10011'
```

For a localized Jira where the epic issue type is not named `Epic`:

```bash
export JIRA_EPIC_ISSUE_TYPE='Эпик'
```

For an internal certificate authority, prefer its CA bundle over disabling TLS
verification:

```bash
export JIRA_CACERT='/path/to/company-ca.pem'
```

### Safe reruns and partial failures

The script creates or resolves all target epics before moving any issues. If an
exact target summary already exists, it reuses that epic instead of creating a
duplicate. This also makes a run interrupted during issue updates safe to run
again: already moved issues no longer match the source epic, and the remaining
ones are moved.

Jira changes are not transactional. If a request fails, the script stops at
that request and prints Jira's response. Fix the permission, field, or network
problem, run `--dry-run` again, and then rerun the command.

### Troubleshooting

**HTTP 401 / 403**

- Confirm that the token has not expired or been revoked.
- For Jira Cloud, use the Atlassian account email in `JIRA_USER`, not a display
  name, and put the API token in `JIRA_API_TOKEN`.
- For Jira Data Center, put the PAT in `JIRA_TOKEN`.
- Confirm that the token's user can browse the project, create epics, and edit
  all affected issues in the Jira UI.

**Epic Link or Epic Name errors**

- Ask a Jira administrator for the field ids and set `JIRA_EPIC_FIELD` and
  `JIRA_EPIC_NAME_FIELD` explicitly.
- Confirm that the fields are available for the relevant project and issue
  types.

**No epic contains the requested quartal**

- Check the `-q` / `--quartal` value and the epic summaries. Accepted examples
  are `26Q1`, `26Q2`, `26Q3`, and `26Q4`; lowercase `q`, four-digit years, and
  quarter 0 or 5 are not accepted.

**Certificate verification failure**

- Set `JIRA_CACERT` to the organization's CA bundle.
- Use `JIRA_INSECURE=1` only for short-lived diagnosis because it disables
  server certificate verification.

## Security notes

- Never commit tokens or paste them into issue comments and logs.
- Prefer a dedicated automation/service account with only the necessary Jira
  permissions.
- Give tokens an expiration date, store them in a password manager or secrets
  manager, and revoke them when no longer used.
- Unset credentials after use when working on a shared machine:

```bash
unset JIRA_TOKEN JIRA_USER JIRA_API_TOKEN
```
