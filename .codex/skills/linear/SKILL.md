---
name: linear
description: |
  Pre-built Linear GraphQL patterns for Symphony agents. Use the
  `linear_graphql` client tool for raw operations: comment editing, state
  transitions, PR attachments, uploads, and issue creation. Never use schema
  introspection.
---

# Linear GraphQL

Use this skill for raw Linear GraphQL work during Symphony app-server sessions.
Every operation the workflow needs is pre-built below; there is no schema to
discover.

## Primary tool

Use the `linear_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured Linear auth for the session.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed GraphQL operation even if the
  tool call itself completed.
- Keep queries/mutations narrowly scoped; ask only for the fields you need.

## Scoped tracker tools

Some sessions (Claude backend) expose capability-bound tracker tools instead of
raw GraphQL: `tracker_issue_get`, `tracker_workpad_upsert`, and
`tracker_issue_transition` (possibly prefixed `mcp__symphony_tracker__`). When
present, prefer them for reading the current issue, syncing the workpad, and
moving state — they need no IDs. Use the patterns below for everything else.

## Query an issue by key, identifier, or id

Use these progressively:

- Start with `issue(id: $key)` when you have a ticket key such as `MT-686`.
- Fall back to `issues(filter: { id: { eq: $key } })` when you need search
  semantics: it returns an empty list instead of failing for unknown keys.
- Once you have the internal issue id, prefer `issue(id: $id)` for narrower reads.

Lookup by issue key:

```graphql
query IssueByKey($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    branchName
    url
    description
    updatedAt
  }
}
```

Lookup by identifier filter:

```graphql
query IssueByIdentifier($identifier: String!) {
  issues(filter: { id: { eq: $identifier } }, first: 1) {
    nodes {
      id
      identifier
      title
      state {
        id
        name
        type
      }
      project {
        id
        name
      }
      branchName
      url
      description
      updatedAt
    }
  }
}
```

Resolve a key to an internal id:

```graphql
query IssueByIdOrKey($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Read the issue once the internal id is known:

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    url
    description
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

## Find the workpad comment

The workpad is a single persistent Linear comment (see WORKFLOW.md). List the
issue's comments and match the `## Codex Workpad` marker header; ignore resolved
comments while searching.

```graphql
query IssueComments($id: String!) {
  issue(id: $id) {
    id
    comments(first: 100) {
      nodes {
        id
        body
        resolvedAt
        user {
          name
        }
      }
    }
  }
}
```

Reuse the matched comment id for every workpad update; create the workpad
comment only when no active one exists.

## Query team workflow states for an issue

Use this before changing issue state when you need the exact `stateId`:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    id
    team {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

## Edit an existing comment

Use `commentUpdate` through `linear_graphql`:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment {
      id
      body
    }
  }
}
```

## Create a comment

Use `commentCreate` through `linear_graphql`:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

## Move an issue to a different state

Use `issueUpdate` with the destination `stateId`:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      state {
        id
        name
      }
    }
  }
}
```

## Attach a GitHub PR to an issue

Use the GitHub-specific attachment mutation when linking a PR:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(
    issueId: $issueId
    url: $url
    title: $title
    linkKind: links
  ) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

If you only need a plain URL attachment and do not care about GitHub-specific
link metadata, use:

```graphql
mutation AttachURL($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

## Upload a video to a comment

Do this in three steps:

1. Call `linear_graphql` with `fileUpload` to get `uploadUrl`, `assetUrl`, and
   any required upload headers.
2. Upload the local file bytes to `uploadUrl` with `curl -X PUT` and the exact
   headers returned by `fileUpload`.
3. Call `linear_graphql` again with `commentCreate` (or `commentUpdate`) and
   include the resulting `assetUrl` in the comment body.

Useful mutations:

```graphql
mutation FileUpload(
  $filename: String!
  $contentType: String!
  $size: Int!
  $makePublic: Boolean
) {
  fileUpload(
    filename: $filename
    contentType: $contentType
    size: $size
    makePublic: $makePublic
  ) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers {
        key
        value
      }
    }
  }
}
```

## Create a follow-up issue

Use this for out-of-scope improvements discovered during execution (see
WORKFLOW.md): a `Backlog` issue in the same project, linked `related` to the
current issue, plus a blocking relation when the follow-up depends on the
current issue.

1. Resolve the project, team, and `Backlog` `stateId` from the project slug
   (`tracker.provider.project_slug` in WORKFLOW.md):

```graphql
query ProjectBySlug($slug: String!) {
  projects(filter: { slugId: { eq: $slug } }, first: 1) {
    nodes {
      id
      teams {
        nodes {
          id
          key
          states {
            nodes {
              id
              name
            }
          }
        }
      }
    }
  }
}
```

2. Create the issue:

```graphql
mutation CreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id
      identifier
      url
    }
  }
}
```

`$input` fields: `title`, `teamId`, `projectId`, `description`, and `stateId`
(the `Backlog` state from step 1). `priority` is optional (0–4).

3. Link it to the current issue:

```graphql
mutation RelateIssues($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) {
    success
  }
}
```

- `related` link:
  `{ issueId: <follow-up id>, relatedIssueId: <current id>, type: related }`.
- Follow-up depends on the current issue:
  `{ issueId: <current id>, relatedIssueId: <follow-up id>, type: blocks }`.
  There is no `blockedBy` relation type; express "follow-up is blocked by
  current" as `blocks` from the current issue to the follow-up.

## Usage rules

- **No introspection.** Never send `__type` or `__schema` queries. They burn
  tokens and calls on both the agent and the tracker side. Every operation
  this workflow needs is pre-built above; if something is missing, record the
  gap in the workpad instead of probing the schema.
- Use `linear_graphql` for comment edits, uploads, and ad-hoc Linear API
  queries.
- Prefer the narrowest issue lookup that matches what you already know:
  key -> identifier search -> internal id.
- For state transitions, fetch team states first and use the exact `stateId`
  instead of hardcoding names inside mutations.
- Prefer `attachmentLinkGitHubPR` over a generic URL attachment when linking a
  GitHub PR to a Linear issue.
- Do not introduce new raw-token shell helpers for GraphQL access.
- If you need shell work for uploads, only use it for signed upload URLs
  returned by `fileUpload`; those URLs already carry the needed authorization.
