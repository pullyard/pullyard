using System.Text.Json;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Stacks;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class PRContextTests : IDisposable
{
    private readonly string dir = Path.Combine(Path.GetTempPath(), "prctx-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
    }

    private static PRContextSnapshot Snapshot() => new()
    {
        Repo = "o/r", Number = 7, Title = "Fix login", Url = "https://github.com/o/r/pull/7", State = "OPEN", IsDraft = false, Author = "alice",
        BaseRef = "main", HeadRef = "fix", HeadOid = "abcdef1234", Body = "Body text", MergeStatus = "1 required check failed",
        Requirements = new() { new("blocking", "1 required check failed", "build"), new("met", "No conflicts with main", null) },
        Checks = new() { new("lint", "success", false, null), new("CI / build", "failure", true, "https://ci/1") },
        Reviews = new() { new("bob", "CHANGES_REQUESTED") },
        Threads = new()
        {
            new("a.swift", 3, false, false, new() { new("bob", "Rename this") }),
            new("b.swift", null, true, true, new() { new("bob", "Done") })
        },
        Files = new() { "a.swift", "b.swift", "README.md" },
        CodeOwners = new() { new(new() { "@core" }, new() { "a.swift", "b.swift" }) },
        UnownedFiles = new() { "README.md" },
        ReviewedOid = "1111111aaa", CommitsSinceReview = 2, Captured = DateTimeOffset.FromUnixTimeSeconds(0)
    };

    private StackNotesMcpServer Server(string account = "me") => new(account, "github.com", Path.Combine(dir, "stack-notes.json"), contextDirectory: dir);

    private static (string Text, bool Error) Call(StackNotesMcpServer server, string name, JsonObject args)
    {
        var reply = server.Handle(new JsonObject
        {
            ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "tools/call",
            ["params"] = new JsonObject { ["name"] = name, ["arguments"] = args }
        })!;
        var result = reply["result"]!;
        return (result["content"]![0]!["text"]!.GetValue<string>(), result["isError"]?.GetValue<bool>() ?? false);
    }

    [Fact]
    public void StoreRoundTripAndSafeFileName()
    {
        var key = StackNotesFile.Key("Me", "github.com", "O/R", 7);
        Assert.DoesNotContain("/", PRContextStore.FileName(key));
        Assert.DoesNotContain("|", PRContextStore.FileName(key));
        Assert.DoesNotContain("#", PRContextStore.FileName(key));
        PRContextStore.Write(Snapshot(), key, dir);
        var read = PRContextStore.Read(key, dir);
        Assert.NotNull(read);
        Assert.Equal(PRContextStore.Serialize(Snapshot()), PRContextStore.Serialize(read!));
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(0), read!.Captured);
        if (!OperatingSystem.IsWindows())
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(dir));
    }

    [Fact]
    public void JsonUsesSharedShape()
    {
        var json = JsonNode.Parse(PRContextStore.Serialize(Snapshot()))!;
        Assert.Equal("1970-01-01T00:00:00Z", json["captured"]!.GetValue<string>());
        Assert.Equal("abcdef1234", json["headOid"]!.GetValue<string>());
        Assert.True(json["checks"]![1]!["required"]!.GetValue<bool>());
        Assert.Equal("@core", json["codeOwners"]![0]!["owners"]![0]!.GetValue<string>());
        Assert.Null(json["threads"]![1]!["line"]);
        var swift = """{"repo":"o/r","number":7,"title":"T","url":"u","state":"OPEN","isDraft":true,"baseRef":"main","headRef":"f","headOid":"h","body":"","mergeStatus":"Draft","requirements":[],"checks":[],"reviews":[],"threads":[{"path":"a","resolved":false,"outdated":true,"comments":[{"author":"bob","body":"x"}]}],"files":["a"],"captured":"2026-01-02T03:04:05Z"}""";
        var decoded = PRContextStore.Deserialize(swift)!;
        Assert.True(decoded.IsDraft);
        Assert.Null(decoded.CodeOwners);
        Assert.True(decoded.Threads[0].Outdated);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero), decoded.Captured);
    }

    [Fact]
    public void PruneDropsOldFiles()
    {
        PRContextStore.Write(Snapshot(), "k1", dir);
        var file = Path.Combine(dir, PRContextStore.FileName("k1"));
        File.SetLastWriteTimeUtc(file, DateTime.UtcNow.AddDays(-8));
        PRContextStore.Prune(dir);
        Assert.Null(PRContextStore.Read("k1", dir));
    }

    [Fact]
    public void PruneKeepsNewestFiles()
    {
        Directory.CreateDirectory(dir);
        for (var i = 0; i < PRContextStore.MaxFiles + 2; i++)
        {
            var path = Path.Combine(dir, $"f{i}.json");
            File.WriteAllText(path, "{}");
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(-i));
        }
        PRContextStore.Prune(dir);
        Assert.Equal(PRContextStore.MaxFiles, Directory.GetFiles(dir, "*.json").Length);
        Assert.False(File.Exists(Path.Combine(dir, $"f{PRContextStore.MaxFiles + 1}.json")));
        Assert.True(File.Exists(Path.Combine(dir, "f0.json")));
    }

    [Fact]
    public void ToolsReadSnapshot()
    {
        var server = Server();
        PRContextStore.Write(Snapshot(), StackNotesFile.Key("me", "github.com", "o/r", 7), dir);
        var (overview, err) = Call(server, "get_pull_request", new JsonObject { ["repo"] = "o/r", ["pr"] = 7 });
        Assert.False(err);
        Assert.Contains("Merge status: 1 required check failed", overview);
        Assert.Contains("- [blocking] 1 required check failed — build", overview);
        Assert.Contains("@bob (changes requested)", overview);
        Assert.Contains("Code owners: @core (2 files)", overview);
        Assert.Contains("last reviewed commit 1111111, 2 commit(s) ago", overview);
        Assert.Contains("1 unresolved review thread(s), 1 failing check(s), 3 changed file(s).", overview);
        Assert.StartsWith("o/r#7: Fix login\nState: open · fix → main · head abcdef1 · by @alice\nURL: https://github.com/o/r/pull/7\nLoaded by PullYard: 1970-01-01T00:00:00Z\n", overview);

        var (threads, _) = Call(server, "list_review_threads", new JsonObject { ["repo"] = "o/r", ["pr"] = 7 });
        Assert.Equal("1. a.swift:3\n   @bob: Rename this", threads);
        var (all, _) = Call(server, "list_review_threads", new JsonObject { ["repo"] = "o/r", ["pr"] = 7, ["include_resolved"] = true });
        Assert.Contains("2. b.swift (resolved, outdated)", all);

        var (checks, _) = Call(server, "list_checks", new JsonObject { ["repo"] = "o/r", ["pr"] = "7" });
        Assert.Equal("- [failure] CI / build · required · https://ci/1\n- [success] lint · optional", checks);

        var (files, _) = Call(server, "list_changed_files", new JsonObject { ["repo"] = "o/r", ["pr"] = 7 });
        Assert.Equal("a.swift — @core\nb.swift — @core\nREADME.md", files);
    }

    [Fact]
    public void MissingSnapshotIsAnError()
    {
        var (text, err) = Call(Server(), "get_pull_request", new JsonObject { ["repo"] = "o/r", ["pr"] = 8 });
        Assert.True(err);
        Assert.Equal("PullYard has no context for o/r#8. Ask the user to open that pull request in PullYard, then try again.", text);
    }

    [Fact]
    public void BadArgumentsAreRejected()
    {
        var (text, err) = Call(Server(), "list_checks", new JsonObject { ["repo"] = "nope", ["pr"] = 1 });
        Assert.True(err);
        Assert.Contains("owner/name", text);
    }

    [Fact]
    public void OtherAccountSnapshotIsNotVisible()
    {
        PRContextStore.Write(Snapshot(), StackNotesFile.Key("work", "github.com", "o/r", 7), dir);
        Assert.True(Call(Server(), "list_checks", new JsonObject { ["repo"] = "o/r", ["pr"] = 7 }).Error);
    }

    [Fact]
    public void DefaultContextDirectorySitsNextToNotes()
    {
        var server = new StackNotesMcpServer("me", "github.com", Path.Combine(dir, "stack-notes.json"));
        Assert.Equal(Path.Combine(dir, "pr-context"), server.ContextDirectory);
    }

    [Fact]
    public void PublisherMapsModel()
    {
        var json = new JsonObject
        {
            ["id"] = "PR_1", ["number"] = 7, ["title"] = "T", ["url"] = "u", ["state"] = "OPEN", ["isDraft"] = false, ["merged"] = false, ["mergeable"] = "MERGEABLE",
            ["mergeStateStatus"] = "BLOCKED", ["body"] = "b", ["bodyHTML"] = "", ["createdAt"] = "2026-01-01T00:00:00Z", ["headRefName"] = "f", ["baseRefName"] = "main",
            ["headRefOid"] = "h",
            ["labels"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["reviewRequests"] = new JsonObject { ["nodes"] = new JsonArray(new JsonObject { ["requestedReviewer"] = new JsonObject { ["__typename"] = "Team", ["name"] = "Core", ["combinedSlug"] = "o/core" } }) },
            ["latestOpinionatedReviews"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["lastCommit"] = new JsonObject
            {
                ["nodes"] = new JsonArray(new JsonObject
                {
                    ["commit"] = new JsonObject
                    {
                        ["oid"] = "h",
                        ["statusCheckRollup"] = new JsonObject
                        {
                            ["state"] = "FAILURE",
                            ["contexts"] = new JsonObject
                            {
                                ["nodes"] = new JsonArray(new JsonObject
                                {
                                    ["__typename"] = "CheckRun", ["databaseId"] = 1, ["name"] = "build", ["status"] = "COMPLETED", ["conclusion"] = "FAILURE", ["isRequired"] = true,
                                    ["checkSuite"] = new JsonObject { ["workflowRun"] = new JsonObject { ["databaseId"] = 9, ["workflow"] = new JsonObject { ["name"] = "CI" } } }
                                })
                            }
                        }
                    }
                })
            },
            ["reviewThreads"] = new JsonObject
            {
                ["nodes"] = new JsonArray(new JsonObject
                {
                    ["id"] = "t", ["isResolved"] = false, ["isOutdated"] = false, ["path"] = "a", ["originalLine"] = 2, ["diffSide"] = "RIGHT",
                    ["comments"] = new JsonObject { ["nodes"] = new JsonArray(new JsonObject { ["id"] = "c", ["author"] = new JsonObject { ["login"] = "bob", ["avatarUrl"] = "" }, ["body"] = "fix", ["bodyHTML"] = "", ["createdAt"] = "2026-01-01T00:00:00Z" }) }
                })
            }
        };
        var pr = JsonSerializer.Deserialize<PullRequestDetail>(json.ToJsonString(), Json.GraphQL)!;
        var reqs = MergeReadiness.Requirements(pr, RulesStatus.Loading);
        var s = PRContextPublisher.Snapshot(new ItemRef(new RepoRef("o", "r"), 7), pr, reqs, null, new[] { "a" }, null, "1 check failed");
        Assert.Equal(new PRContextCheck("CI / build", "failure", true, null), Assert.Single(s.Checks));
        Assert.Equal(new PRContextReview("o/core", "REVIEW_REQUESTED"), Assert.Single(s.Reviews));
        var thread = Assert.Single(s.Threads);
        Assert.Equal(2, thread.Line);
        Assert.Equal(new PRContextComment("bob", "fix"), Assert.Single(thread.Comments));
        Assert.Equal("1 check failed", s.MergeStatus);
        Assert.Contains(s.Requirements, r => r.State == "blocking" && r.Title == "1 required check failed");
        Assert.Null(s.CodeOwners);
        Assert.Null(s.ReviewedOid);
        Assert.Equal("o/r", s.Repo);
    }
}
