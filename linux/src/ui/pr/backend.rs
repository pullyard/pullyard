use std::collections::HashSet;

use serde_json::json;

use crate::api::code_owners::CodeOwners;
use crate::api::models::{CheckContext, ItemRef, PendingComment, PrDetailResponse, PrFile, PrLight, PullRequestDetail};
use crate::api::queries as q;
use crate::api::{ApiError, ApiResult, GitHubApi};
use crate::diff::DiffFile;
use crate::forge::bitbucket_review::BitbucketReview;
use crate::forge::gitlab_review::GitLabReview;
use crate::git_accounts::GitProvider;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrAction {
    Close,
    Reopen,
    ReadyForReview,
    ConvertToDraft,
    UpdateBranch,
    DisableAutoMerge,
    Enqueue,
    Dequeue,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct PrFeatures {
    pub provider: GitProvider,
    pub stack: bool,
    pub viewed_files: bool,
    pub request_reviewers: bool,
    pub editing: bool,
    pub draft_toggle: bool,
    pub update_branch: bool,
    pub rerun_checks: bool,
    pub job_logs: bool,
    pub request_changes: bool,
    pub revoke_approval: bool,
    pub agent: bool,
    pub blame: bool,
    pub delete_branch: bool,
    pub branch_rules: bool,
    pub reopen: bool,
    pub merge_queue: bool,
}

impl PrFeatures {
    pub fn github(provider: GitProvider) -> Self {
        PrFeatures {
            provider,
            stack: true,
            viewed_files: true,
            request_reviewers: true,
            editing: true,
            draft_toggle: true,
            update_branch: true,
            rerun_checks: true,
            job_logs: true,
            request_changes: true,
            revoke_approval: false,
            agent: true,
            blame: true,
            delete_branch: true,
            branch_rules: true,
            reopen: true,
            merge_queue: true,
        }
    }

    pub fn gitlab() -> Self {
        PrFeatures {
            provider: GitProvider::Gitlab,
            stack: false,
            viewed_files: false,
            request_reviewers: false,
            editing: true,
            draft_toggle: true,
            update_branch: true,
            rerun_checks: false,
            job_logs: true,
            request_changes: false,
            revoke_approval: true,
            agent: false,
            blame: false,
            delete_branch: false,
            branch_rules: false,
            reopen: true,
            merge_queue: true,
        }
    }

    pub fn bitbucket() -> Self {
        PrFeatures {
            provider: GitProvider::Bitbucket,
            stack: false,
            viewed_files: false,
            request_reviewers: false,
            editing: true,
            draft_toggle: true,
            update_branch: false,
            rerun_checks: false,
            job_logs: true,
            request_changes: true,
            revoke_approval: true,
            agent: false,
            blame: false,
            delete_branch: false,
            branch_rules: false,
            reopen: false,
            merge_queue: false,
        }
    }

    pub fn is_gitlab(&self) -> bool {
        self.provider == GitProvider::Gitlab
    }

    pub fn checks_title(&self) -> &'static str {
        match self.provider {
            GitProvider::Gitlab => "Pipeline",
            GitProvider::Bitbucket => "Builds",
            _ => "Checks",
        }
    }

    pub fn update_branch_title(&self) -> &'static str {
        if self.is_gitlab() {
            "Rebase"
        } else {
            "Update branch"
        }
    }

    pub fn queue_title(&self) -> &'static str {
        if self.is_gitlab() {
            "merge train"
        } else {
            "merge queue"
        }
    }

    pub fn service_title(&self) -> &'static str {
        self.provider.title()
    }

    pub fn number_prefix(&self) -> &'static str {
        self.provider.number_prefix()
    }

    pub fn request_title(&self) -> &'static str {
        self.provider.request_title()
    }
}

#[derive(Clone)]
pub enum PrBackend {
    GitHub(GitHubApi, GitProvider),
    GitLab(GitLabReview),
    Bitbucket(BitbucketReview),
}

fn unsupported(provider: GitProvider) -> ApiError {
    ApiError::new(format!("Not available for {} yet", provider.title()))
}

impl PrBackend {
    pub fn features(&self) -> PrFeatures {
        match self {
            PrBackend::GitHub(_, provider) => PrFeatures::github(*provider),
            PrBackend::GitLab(_) => PrFeatures::gitlab(),
            PrBackend::Bitbucket(_) => PrFeatures::bitbucket(),
        }
    }

    pub fn github(&self) -> Option<&GitHubApi> {
        match self {
            PrBackend::GitHub(api, _) => Some(api),
            PrBackend::GitLab(_) | PrBackend::Bitbucket(_) => None,
        }
    }

    pub fn host(&self) -> String {
        match self {
            PrBackend::GitHub(api, _) => api.host().to_string(),
            PrBackend::GitLab(lab) => lab.host(),
            PrBackend::Bitbucket(bb) => bb.host(),
        }
    }

    pub async fn load(&self, r: &ItemRef) -> ApiResult<PrDetailResponse> {
        match self {
            PrBackend::GitHub(api, _) => api.pull_request(r).await,
            PrBackend::GitLab(lab) => lab.load(r).await,
            PrBackend::Bitbucket(bb) => bb.load(r).await,
        }
    }

    pub async fn pulse(&self, r: &ItemRef) -> ApiResult<Option<PrLight>> {
        match self {
            PrBackend::GitHub(api, _) => api.pull_request_light(r).await,
            PrBackend::GitLab(lab) => lab.pulse(r).await,
            PrBackend::Bitbucket(bb) => bb.pulse(r).await,
        }
    }

    pub async fn files(&self, r: &ItemRef) -> ApiResult<Vec<PrFile>> {
        match self {
            PrBackend::GitHub(api, _) => api.pull_request_files(r).await,
            PrBackend::GitLab(lab) => lab.files(r).await,
            PrBackend::Bitbucket(bb) => bb.files(r).await,
        }
    }

    pub async fn comment(&self, r: &ItemRef, pr: &PullRequestDetail, body: &str) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.add_comment(&pr.id, body).await,
            PrBackend::GitLab(lab) => lab.comment(r, body).await,
            PrBackend::Bitbucket(bb) => bb.comment(r, body).await,
        }
    }

    pub async fn submit_review(&self, r: &ItemRef, pr: &PullRequestDetail, event: &str, body: Option<String>, comments: &[PendingComment], files: &[DiffFile]) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.add_review(&pr.id, event, body, comments).await,
            PrBackend::GitLab(lab) => lab.submit_review(r, pr, event, body.as_deref().unwrap_or(""), comments, files).await,
            PrBackend::Bitbucket(bb) => bb.submit_review(r, event, body.as_deref().unwrap_or(""), comments).await,
        }
    }

    pub async fn reply(&self, r: &ItemRef, thread: &str, body: &str) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.mutate(q::REPLY_THREAD, json!({ "id": thread, "b": body })).await,
            PrBackend::GitLab(lab) => lab.reply(r, thread, body).await,
            PrBackend::Bitbucket(bb) => bb.reply(r, thread, body).await,
        }
    }

    pub async fn set_resolved(&self, r: &ItemRef, thread: &str, resolved: bool) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.mutate(if resolved { q::RESOLVE_THREAD } else { q::UNRESOLVE_THREAD }, json!({ "id": thread })).await,
            PrBackend::GitLab(lab) => lab.set_resolved(r, thread, resolved).await,
            PrBackend::Bitbucket(bb) => bb.set_resolved(r, thread, resolved).await,
        }
    }

    pub async fn merge(&self, r: &ItemRef, pr: &PullRequestDetail, method: &str, title: Option<String>, body: Option<String>, delete_branch: bool) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => {
                api.mutate(q::MERGE, json!({ "id": pr.id, "m": method, "t": title, "b": body })).await?;
                if delete_branch {
                    if let Some(head) = pr.head_repository.as_ref() {
                        let _ = api.delete_branch(&head.name_with_owner, &pr.head_ref_name).await;
                    }
                }
                Ok(())
            }
            PrBackend::GitLab(lab) => lab.merge(r, pr, method, title, body, delete_branch).await,
            PrBackend::Bitbucket(bb) => bb.merge(r, pr, method, title, body, delete_branch).await,
        }
    }

    pub async fn enable_auto_merge(&self, r: &ItemRef, pr: &PullRequestDetail, method: &str) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.mutate(q::ENABLE_AUTO_MERGE, json!({ "id": pr.id, "m": method })).await,
            PrBackend::GitLab(lab) => lab.enable_auto_merge(r, pr, method).await,
            PrBackend::Bitbucket(_) => Err(unsupported(GitProvider::Bitbucket)),
        }
    }

    pub async fn perform(&self, action: PrAction, r: &ItemRef, pr: &PullRequestDetail) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => {
                let mutation = match action {
                    PrAction::Close => q::CLOSE_PR,
                    PrAction::Reopen => q::REOPEN_PR,
                    PrAction::ReadyForReview => q::READY_FOR_REVIEW,
                    PrAction::ConvertToDraft => q::CONVERT_TO_DRAFT,
                    PrAction::UpdateBranch => q::UPDATE_BRANCH,
                    PrAction::DisableAutoMerge => q::DISABLE_AUTO_MERGE,
                    PrAction::Dequeue => q::DEQUEUE,
                    PrAction::Enqueue => {
                        let mut vars = json!({ "id": pr.id });
                        if !pr.head_ref_oid.is_empty() {
                            vars["oid"] = json!(pr.head_ref_oid);
                        }
                        return api.mutate(q::ENQUEUE, vars).await;
                    }
                };
                api.mutate(mutation, json!({ "id": pr.id })).await
            }
            PrBackend::GitLab(lab) => match action {
                PrAction::Close => lab.close(r, false).await,
                PrAction::Reopen => lab.close(r, true).await,
                PrAction::ReadyForReview => lab.set_draft(r, pr, false).await,
                PrAction::ConvertToDraft => lab.set_draft(r, pr, true).await,
                PrAction::UpdateBranch => lab.rebase(r).await,
                PrAction::DisableAutoMerge | PrAction::Dequeue => lab.cancel_auto_merge(r).await,
                PrAction::Enqueue => lab.add_to_train(r, (!pr.head_ref_oid.is_empty()).then_some(pr.head_ref_oid.as_str())).await,
            },
            PrBackend::Bitbucket(bb) => match action {
                PrAction::Close => bb.decline(r).await,
                PrAction::ReadyForReview => bb.set_draft(r, false).await,
                PrAction::ConvertToDraft => bb.set_draft(r, true).await,
                PrAction::Reopen | PrAction::UpdateBranch | PrAction::DisableAutoMerge | PrAction::Enqueue | PrAction::Dequeue => Err(unsupported(GitProvider::Bitbucket)),
            },
        }
    }

    pub async fn edit(&self, r: &ItemRef, pr: &PullRequestDetail, title: &str, body: &str) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.mutate(q::EDIT_PR, json!({ "id": pr.id, "t": title, "b": body })).await,
            PrBackend::GitLab(lab) => lab.edit(r, title, body).await,
            PrBackend::Bitbucket(bb) => bb.edit(r, title, body).await,
        }
    }

    pub async fn revoke_approval(&self, r: &ItemRef) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(_, provider) => Err(unsupported(*provider)),
            PrBackend::GitLab(lab) => lab.revoke_approval(r).await,
            PrBackend::Bitbucket(bb) => bb.approve(r, false).await,
        }
    }

    pub async fn request_reviewers(&self, r: &ItemRef, logins: &[String]) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.request_reviewers(r, logins).await,
            PrBackend::GitLab(_) => Err(unsupported(GitProvider::Gitlab)),
            PrBackend::Bitbucket(_) => Err(unsupported(GitProvider::Bitbucket)),
        }
    }

    pub async fn delete_branch(&self, pr: &PullRequestDetail) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => match pr.head_repository.as_ref() {
                Some(head) => api.delete_branch(&head.name_with_owner, &pr.head_ref_name).await,
                None => Ok(()),
            },
            PrBackend::GitLab(_) => Err(unsupported(GitProvider::Gitlab)),
            PrBackend::Bitbucket(_) => Err(unsupported(GitProvider::Bitbucket)),
        }
    }

    pub async fn set_viewed(&self, pr: &PullRequestDetail, path: &str, viewed: bool) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => api.mutate(if viewed { q::MARK_VIEWED } else { q::UNMARK_VIEWED }, json!({ "id": pr.id, "p": path })).await,
            PrBackend::GitLab(_) => Err(unsupported(GitProvider::Gitlab)),
            PrBackend::Bitbucket(_) => Err(unsupported(GitProvider::Bitbucket)),
        }
    }

    pub fn can_show_log(&self, check: &CheckContext) -> bool {
        match self {
            PrBackend::GitHub(..) => check.is_actions_job(),
            PrBackend::GitLab(_) => GitLabReview::can_show_log(check),
            PrBackend::Bitbucket(_) => BitbucketReview::can_show_log(check),
        }
    }

    pub async fn code_owners(&self, r: &ItemRef, base: &str) -> ApiResult<Option<CodeOwners>> {
        match self {
            PrBackend::GitHub(api, _) => api.code_owners(&r.repo, base).await,
            PrBackend::GitLab(lab) => lab.code_owners(r, base).await,
            PrBackend::Bitbucket(bb) => bb.code_owners(r, base).await,
        }
    }

    pub async fn job_log(&self, r: &ItemRef, check: &CheckContext) -> ApiResult<String> {
        match self {
            PrBackend::GitHub(api, _) => {
                let Some(id) = check.database_id else { return Err(ApiError::new("This check has no job log. Open it on GitHub to see its output.")) };
                api.job_log(&r.repo, id).await
            }
            PrBackend::GitLab(lab) => lab.job_log(r, check).await,
            PrBackend::Bitbucket(bb) => bb.job_log(r, check).await,
        }
    }

    pub async fn rerun_failed(&self, r: &ItemRef, runs: HashSet<i64>) -> ApiResult<()> {
        match self {
            PrBackend::GitHub(api, _) => {
                for id in runs {
                    api.rerun_failed_jobs(&r.repo, id).await?;
                }
                Ok(())
            }
            PrBackend::GitLab(_) => Err(unsupported(GitProvider::Gitlab)),
            PrBackend::Bitbucket(_) => Err(unsupported(GitProvider::Bitbucket)),
        }
    }
}

#[cfg(test)]
mod job_log_tests {
    use std::sync::Arc;

    use super::*;
    use crate::api::code_owners::CodeOwnersFlavor;
    use crate::api::models::RepoRef;
    use crate::forge::bitbucket_review::build_number;
    use crate::forge::gitlab_review::clean_trace;
    use crate::forge::stub::Stub;
    use crate::forge::ForgeClient;

    fn check(typename: &str, id: Option<i64>, conclusion: Option<&str>, link: Option<&str>) -> CheckContext {
        serde_json::from_value(json!({
            "__typename": typename,
            "databaseId": id,
            "name": "unit",
            "status": if conclusion.is_none() { "IN_PROGRESS" } else { "COMPLETED" },
            "conclusion": conclusion,
            "detailsUrl": link,
        }))
        .unwrap()
    }

    fn bitbucket(stub: Arc<Stub>) -> PrBackend {
        PrBackend::Bitbucket(BitbucketReview::new(ForgeClient::stubbed(GitProvider::Bitbucket, "bitbucket.org", "s", stub)))
    }

    #[test]
    fn gitlab_trace_cleanup() {
        let raw = "section_start:1700000000:prepare_script\r\u{1b}[0K\u{1b}[0K\u{1b}[36;1mPreparing\u{1b}[0;m\nprogress 10%\rprogress 100%\n\u{1b}[31mERROR: tests failed\u{1b}[0m\nsection_end:1700000001:prepare_script\r\u{1b}[0K";
        assert_eq!(clean_trace(raw), "Preparing\nprogress 100%\nERROR: tests failed\n");
    }

    #[test]
    fn gitlab_job_log() {
        let stub = Arc::new(Stub::default());
        stub.route("/jobs/3/trace", 200, "line one\nERROR boom");
        let backend = PrBackend::GitLab(GitLabReview::new(ForgeClient::stubbed(GitProvider::Gitlab, "gitlab.example.com", "s", stub.clone())));
        let r = ItemRef { repo: RepoRef::new("group", "app"), number: 1 };
        assert!(backend.features().job_logs);
        assert!(backend.can_show_log(&check("GitLabJob", Some(3), Some("FAILURE"), None)));
        assert!(!backend.can_show_log(&check("GitLabJob", Some(3), None, None)));
        assert!(!backend.can_show_log(&check("GitLabJob", Some(3), Some("SKIPPED"), None)));
        assert!(!backend.can_show_log(&check("CheckRun", Some(3), Some("FAILURE"), None)));
        let log = crate::rt::block_on(backend.job_log(&r, &check("GitLabJob", Some(3), Some("FAILURE"), None))).unwrap();
        assert_eq!(log, "line one\nERROR boom");
        let last = stub.all().last().cloned().unwrap();
        assert_eq!(last.accept, "text/plain");
        assert!(last.path.ends_with("/projects/group/app/jobs/3/trace"));
    }

    #[test]
    fn bitbucket_build_number() {
        assert_eq!(build_number(Some("https://bitbucket.org/acme/api/pipelines/results/42")), Some(42));
        assert_eq!(build_number(Some("https://bitbucket.org/acme/api/addon/pipelines/home#!/results/7")), Some(7));
        assert_eq!(build_number(Some("https://ci.example.com/build/9")), None);
        assert_eq!(build_number(None), None);
    }

    #[test]
    fn bitbucket_pipeline_log() {
        let stub = Arc::new(Stub::default());
        stub.route("/pipelines/42", 200, r#"{"uuid":"{p-1}","build_number":42,"state":{"name":"COMPLETED","result":{"name":"FAILED"}}}"#);
        stub.route("/steps/", 200, r#"{"values":[{"uuid":"{s-1}","name":"Build","state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}}},{"uuid":"{s-2}","name":"Test","state":{"name":"COMPLETED","result":{"name":"FAILED"}}}]}"#);
        stub.route("/steps/{s-1}/log", 200, "compiled\n");
        stub.route("/steps/{s-2}/log", 200, "\u{1b}[31mFAIL\u{1b}[0m test_a\n");
        let backend = bitbucket(stub.clone());
        let r = ItemRef { repo: RepoRef::new("acme", "api"), number: 5 };
        let build = check("BitbucketStatus", Some(1), Some("FAILURE"), Some("https://bitbucket.org/acme/api/pipelines/results/42"));
        assert!(backend.features().job_logs);
        assert!(backend.can_show_log(&build));
        assert!(!backend.can_show_log(&check("BitbucketStatus", Some(1), Some("FAILURE"), Some("https://ci.example.com/9"))));
        assert!(!backend.can_show_log(&check("BitbucketStatus", Some(1), None, Some("https://bitbucket.org/acme/api/pipelines/results/42"))));
        let log = crate::rt::block_on(backend.job_log(&r, &build)).unwrap();
        assert_eq!(log, "=== Build (successful) ===\ncompiled\n\n=== Test (failed) ===\nFAIL test_a");
        assert!(stub.all().iter().all(|q| q.authorized));
    }

    #[test]
    fn bitbucket_log_falls_back_and_follows_redirects_safely() {
        let stub = Arc::new(Stub::default());
        stub.route("/pipelines/42", 404, r#"{"error":{"message":"not found"}}"#);
        stub.route("/pipelines/", 200, r#"{"values":[{"uuid":"{p-0}","build_number":41},{"uuid":"{p-1}","build_number":42}]}"#);
        stub.route("/steps/", 200, r#"{"values":[{"uuid":"{s-1}","name":"Build"},{"uuid":"{s-2}","name":"Deploy","state":{"name":"COMPLETED"}},{"uuid":"{s-3}","name":"Lint"}]}"#);
        stub.route("/steps/{s-1}/log", 302, "/2.0/repositories/acme/api/pipelines/{p-1}/steps/{s-1}/log-moved");
        stub.route("/log-moved", 307, "https://storage.example.com/logs/s1");
        stub.route("/logs/s1", 200, "stored\n");
        stub.route("/steps/{s-2}/log", 302, "http://storage.example.com/logs/s2");
        let backend = bitbucket(stub.clone());
        let r = ItemRef { repo: RepoRef::new("acme", "api"), number: 5 };
        let build = check("BitbucketStatus", Some(1), Some("FAILURE"), Some("https://bitbucket.org/acme/api/addon/pipelines/home#!/results/42"));
        let log = crate::rt::block_on(backend.job_log(&r, &build)).unwrap();
        assert_eq!(log, "=== Build ===\nstored\n\n=== Deploy (completed) ===\nLog unavailable: Bitbucket sent an insecure log address\n\n=== Lint ===\nLog unavailable: Bitbucket 404: 404 Not Found");
        assert_eq!(stub.requests("GET", "/pipelines/").len(), 1);
        assert!(stub.requests("GET", "/pipelines/")[0].url.contains("sort=-created_on"));
        assert!(stub.requests("GET", "/{p-1}/steps/").len() == 1);
        assert!(stub.requests("GET", "/log-moved").iter().all(|q| q.authorized));
        let storage = stub.requests("GET", "/logs/s1");
        assert_eq!(storage.len(), 1);
        assert!(!storage[0].authorized);
        assert!(storage[0].url.starts_with("https://storage.example.com/"));
        assert!(stub.requests("GET", "/logs/s2").is_empty());
    }

    #[test]
    fn github_only_shows_actions_jobs() {
        let backend = PrBackend::GitHub(GitHubApi::new("x"), GitProvider::Github);
        let mut job = check("CheckRun", Some(5), Some("FAILURE"), None);
        job.check_suite = serde_json::from_value(json!({ "workflowRun": { "databaseId": 9, "workflow": { "name": "CI" } } })).unwrap();
        assert!(backend.can_show_log(&job));
        assert!(!backend.can_show_log(&check("StatusContext", None, None, None)));
    }

    #[test]
    fn gitlab_code_owners_read_first_existing_file() {
        let stub = Arc::new(Stub::default());
        stub.route("/repository/files/docs/CODEOWNERS/raw", 200, "[Docs] @writers\n*.md\n");
        let backend = PrBackend::GitLab(GitLabReview::new(ForgeClient::stubbed(GitProvider::Gitlab, "gitlab.example.com", "s", stub.clone())));
        let r = ItemRef { repo: RepoRef::new("group", "app"), number: 1 };
        let owners = crate::rt::block_on(backend.code_owners(&r, "base1")).unwrap().unwrap();
        assert_eq!(owners.path, "docs/CODEOWNERS");
        assert_eq!(owners.flavor, CodeOwnersFlavor::GitLab);
        assert_eq!(owners.owners_for("README.md"), vec!["@writers".to_string()]);
        let urls: Vec<String> = stub.all().into_iter().map(|q| q.url).collect();
        assert!(urls.iter().any(|u| u.contains("files/CODEOWNERS/raw?ref=base1")));
        assert!(urls.iter().any(|u| u.contains("files/docs%2FCODEOWNERS/raw?ref=base1")));
        assert!(!urls.iter().any(|u| u.contains(".gitlab")));
    }

    #[test]
    fn bitbucket_code_owners_and_missing_file() {
        let stub = Arc::new(Stub::default());
        stub.route("/src/base9/.bitbucket/CODEOWNERS", 200, "src/ @acme/core\n");
        let backend = bitbucket(stub.clone());
        let r = ItemRef { repo: RepoRef::new("acme", "api"), number: 5 };
        let owners = crate::rt::block_on(backend.code_owners(&r, "base9")).unwrap().unwrap();
        assert_eq!(owners.path, ".bitbucket/CODEOWNERS");
        assert_eq!(owners.flavor, CodeOwnersFlavor::GitHub);
        assert_eq!(owners.owners_for("src/a.rs"), vec!["@acme/core".to_string()]);
        assert!(stub.all()[0].path.ends_with("/repositories/acme/api/src/base9/.bitbucket/CODEOWNERS"));
        stub.remove("/src/base9/.bitbucket/CODEOWNERS");
        stub.clear_requests();
        assert!(crate::rt::block_on(backend.code_owners(&r, "base9")).unwrap().is_none());
        assert_eq!(stub.all().len(), 2);
        assert!(stub.all()[1].path.ends_with("/src/base9/CODEOWNERS"));
    }

    #[test]
    fn code_owners_errors_other_than_missing_propagate() {
        let stub = Arc::new(Stub::default());
        stub.route("/repository/files/CODEOWNERS/raw", 500, r#"{"message":"boom"}"#);
        let backend = PrBackend::GitLab(GitLabReview::new(ForgeClient::stubbed(GitProvider::Gitlab, "gitlab.example.com", "s", stub)));
        let r = ItemRef { repo: RepoRef::new("group", "app"), number: 1 };
        assert!(crate::rt::block_on(backend.code_owners(&r, "base1")).is_err());
    }
}

#[cfg(test)]
mod merge_queue_tests {
    use std::sync::Arc;

    use super::*;
    use crate::api::models::RepoRef;
    use crate::forge::stub::Stub;
    use crate::forge::ForgeClient;

    fn pr(head: &str) -> PullRequestDetail {
        serde_json::from_value(json!({
            "id": "gitlab-mr-1", "number": 7, "title": "T", "url": "u", "state": "OPEN",
            "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z",
            "headRefName": "f", "baseRefName": "main", "headRefOid": head,
            "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false
        }))
        .unwrap()
    }

    #[test]
    fn mutations_and_features() {
        assert!(q::ENQUEUE.contains("enqueuePullRequest(input: {pullRequestId: $id, expectedHeadOid: $oid})"));
        assert!(q::ENQUEUE.contains("$oid: GitObjectID"));
        assert!(q::DEQUEUE.contains("dequeuePullRequest(input: {id: $id})"));
        assert!(PrFeatures::github(GitProvider::Github).merge_queue);
        assert!(PrFeatures::gitlab().merge_queue);
        assert!(!PrFeatures::bitbucket().merge_queue);
        assert_eq!(PrFeatures::github(GitProvider::Github).queue_title(), "merge queue");
        assert_eq!(PrFeatures::gitlab().queue_title(), "merge train");
    }

    #[test]
    fn gitlab_train_add_and_remove() {
        let stub = Arc::new(Stub::default());
        stub.route("/merge_trains/merge_requests/7", 201, "{}");
        stub.route("/merge_requests/7/cancel_merge_when_pipeline_succeeds", 201, "{}");
        let backend = PrBackend::GitLab(GitLabReview::new(ForgeClient::stubbed(GitProvider::Gitlab, "gitlab.example.com", "s", stub.clone())));
        let r = ItemRef { repo: RepoRef::new("group", "app"), number: 7 };
        crate::rt::block_on(backend.perform(PrAction::Enqueue, &r, &pr("abc123"))).unwrap();
        let adds = stub.requests("POST", "/merge_trains/merge_requests/7");
        assert_eq!(adds.len(), 1);
        assert!(adds[0].path.ends_with("/projects/group/app/merge_trains/merge_requests/7"));
        let body = adds[0].json();
        assert_eq!(body["sha"], "abc123");
        assert_eq!(body["when_pipeline_succeeds"], true);

        crate::rt::block_on(backend.perform(PrAction::Enqueue, &r, &pr(""))).unwrap();
        let unknown = stub.requests("POST", "/merge_trains/merge_requests/7").last().unwrap().json();
        assert!(unknown.get("sha").is_none());
        assert_eq!(unknown["when_pipeline_succeeds"], true);

        crate::rt::block_on(backend.perform(PrAction::Dequeue, &r, &pr("abc123"))).unwrap();
        assert_eq!(stub.requests("POST", "/merge_requests/7/cancel_merge_when_pipeline_succeeds").len(), 1);
    }

    #[test]
    fn bitbucket_rejects_queue_actions() {
        let stub = Arc::new(Stub::default());
        let backend = PrBackend::Bitbucket(BitbucketReview::new(ForgeClient::stubbed(GitProvider::Bitbucket, "bitbucket.org", "s", stub.clone())));
        let r = ItemRef { repo: RepoRef::new("a", "b"), number: 1 };
        for action in [PrAction::Enqueue, PrAction::Dequeue] {
            let e = crate::rt::block_on(backend.perform(action, &r, &pr("h"))).unwrap_err();
            assert_eq!(e.message, "Not available for Bitbucket yet");
        }
        assert!(stub.all().is_empty());
    }
}
