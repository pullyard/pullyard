use std::collections::HashSet;

use serde_json::json;

use crate::api::models::{ItemRef, PendingComment, PrDetailResponse, PrFile, PrLight, PullRequestDetail};
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
            job_logs: false,
            request_changes: false,
            revoke_approval: true,
            agent: false,
            blame: false,
            delete_branch: false,
            branch_rules: false,
            reopen: true,
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
            job_logs: false,
            request_changes: true,
            revoke_approval: true,
            agent: false,
            blame: false,
            delete_branch: false,
            branch_rules: false,
            reopen: false,
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
                };
                api.mutate(mutation, json!({ "id": pr.id })).await
            }
            PrBackend::GitLab(lab) => match action {
                PrAction::Close => lab.close(r, false).await,
                PrAction::Reopen => lab.close(r, true).await,
                PrAction::ReadyForReview => lab.set_draft(r, pr, false).await,
                PrAction::ConvertToDraft => lab.set_draft(r, pr, true).await,
                PrAction::UpdateBranch => lab.rebase(r).await,
                PrAction::DisableAutoMerge => lab.cancel_auto_merge(r).await,
            },
            PrBackend::Bitbucket(bb) => match action {
                PrAction::Close => bb.decline(r).await,
                PrAction::ReadyForReview => bb.set_draft(r, false).await,
                PrAction::ConvertToDraft => bb.set_draft(r, true).await,
                PrAction::Reopen | PrAction::UpdateBranch | PrAction::DisableAutoMerge => Err(unsupported(GitProvider::Bitbucket)),
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
