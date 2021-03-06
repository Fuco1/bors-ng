defmodule BorsNG.WebhookController do
  @moduledoc """
  The webhook controller responds to HTTP requests
  that are initiated from other services (currently, just GitHub).

  For example, I can run `iex -S mix phoenix.server` and do this:

      iex> # Push state to "GitHub"
      iex> alias BorsNG.GitHub
      iex> alias BorsNG.GitHub.ServerMock
      iex> alias BorsNG.Database
      iex> ServerMock.put_state(%{
      ...>   {:installation, 91} => %{ repos: [
      ...>     %GitHub.Repo{
      ...>       id: 14,
      ...>       name: "test/repo",
      ...>       owner: %{
      ...>         id: 6,
      ...>         login: "bors-fanboi",
      ...>         avatar_url: "data:image/svg+xml,<svg></svg>",
      ...>         type: :user
      ...>       }}
      ...>   ] },
      ...>   {{:installation, 91}, 14} => %{
      ...>     branches: %{},
      ...>     comments: %{1 => []},
      ...>     pulls: %{
      ...>       1 => %GitHub.Pr{
      ...>         number: 1,
      ...>         title: "Test",
      ...>         body: "Mess",
      ...>         state: :open,
      ...>         base_ref: "master",
      ...>         head_sha: "00000001",
      ...>         user: %GitHub.User{
      ...>           id: 6,
      ...>           login: "bors-fanboi",
      ...>           avatar_url: "data:image/svg+xml,<svg></svg>"}}},
      ...>     statuses: %{},
      ...>     files: %{}}})
      iex> # The installation now exists; notify bors about it.
      iex> BorsNG.WebhookController.do_webhook(%{
      ...>   body_params: %{
      ...>     "installation" => %{ "id" => 91 },
      ...>     "sender" => %{
      ...>       "id" => 6,
      ...>       "login" => "bors-fanboi",
      ...>       "avatar_url" => "" },
      ...>     "action" => "created" }}, "github", "installation")
      iex> proj = Database.Repo.get_by!(Database.Project, repo_xref: 14)
      iex> proj.name
      "test/repo"
      iex> # This has also started a (background) sync of all attached patches.
      iex> # Watch it happen in the user interface.
      iex> BorsNG.Worker.Syncer.wait_hot_spin(proj.id)
      iex> patch = Database.Repo.get_by!(Database.Patch, pr_xref: 1)
      iex> patch.title
      "Test"
  """

  use BorsNG.Web, :controller

  require Logger

  @allow_private_repos Application.get_env(
    :bors_frontend, BorsNG)[:allow_private_repos]

  alias BorsNG.Worker.Attemptor
  alias BorsNG.Worker.Batcher
  alias BorsNG.Command
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.LinkUserProject
  alias BorsNG.GitHub
  alias BorsNG.Worker.Syncer

  @doc """
  This action is reached via `/webhook/:provider`
  """
  def webhook(conn, %{"provider" => "github"}) do
    event = hd(get_req_header(conn, "x-github-event"))
    do_webhook conn, "github", event
    conn
    |> send_resp(200, "")
  end

  def do_webhook(_conn, "github", "ping") do
    :ok
  end

  def do_webhook(conn, "github", "installation") do
    payload = conn.body_params
    installation_xref = payload["installation"]["id"]
    sender = payload["sender"]
    |> GitHub.User.from_json!()
    |> Syncer.sync_user()
    case payload["action"] do
      "deleted" -> Repo.delete_all(from(
        i in Installation,
        where: i.installation_xref == ^installation_xref
      ))
      "created" -> Repo.transaction(fn ->
        create_installation_by_xref(installation_xref, sender)
      end)
      _ -> nil
    end
    :ok
  end

  def do_webhook(conn, "github", "installation_repositories") do
    payload = conn.body_params
    installation_xref = payload["installation"]["id"]
    installation = Repo.get_by!(
      Installation,
      installation_xref: installation_xref)
    :ok = case payload["action"] do
      "removed" -> :ok
      "added" -> :ok
    end
    sender = payload["sender"]
    |> GitHub.User.from_json!()
    |> Syncer.sync_user()
    payload["repositories_removed"]
    |> Enum.map(&from(p in Project, where: p.repo_xref == ^&1["id"]))
    |> Enum.each(&Repo.delete_all/1)
    {:installation, installation_xref}
    |> GitHub.get_installation_repos!()
    |> Enum.filter(&(@allow_private_repos || !&1.private))
    |> Enum.filter(& is_nil Repo.get_by(Project, repo_xref: &1.id))
    |> Enum.map(&%Project{
      repo_xref: &1.id,
      name: &1.name,
      installation_id: installation.id})
    |> Enum.map(&Repo.insert!/1)
    |> Enum.map(&%LinkUserProject{user_id: sender.id, project_id: &1.id})
    |> Enum.map(&Repo.insert!/1)
    |> Enum.each(fn %LinkUserProject{project_id: project_id} ->
      Syncer.start_synchronize_project(project_id)
    end)
    :ok
  end

  def do_webhook(conn, "github", "pull_request") do
    repo_xref = conn.body_params["repository"]["id"]
    project = Repo.get_by!(Project, repo_xref: repo_xref)
    pr = BorsNG.GitHub.Pr.from_json!(conn.body_params["pull_request"])
    patch = Syncer.sync_patch(project.id, pr)
    do_webhook_pr(conn, %{
      action: conn.body_params["action"],
      project: project,
      patch: patch,
      author: patch.author})
  end

  def do_webhook(conn, "github", "issue_comment") do
    is_created = conn.body_params["action"] == "created"
    is_pr = Map.has_key?(conn.body_params["issue"], "pull_request")
    if is_created and is_pr do
      project = Repo.get_by!(Project,
        repo_xref: conn.body_params["repository"]["id"])
      commenter = conn.body_params["comment"]["user"]
      |> GitHub.User.from_json!()
      |> Syncer.sync_user()
      comment = conn.body_params["comment"]["body"]
      %Command{
        project: project,
        commenter: commenter,
        comment: comment,
        pr_xref: conn.body_params["issue"]["number"]}
      |> Command.run()
    end
  end

  def do_webhook(conn, "github", "pull_request_review_comment") do
    is_created = conn.body_params["action"] == "created"
    if is_created do
      project = Repo.get_by!(Project,
        repo_xref: conn.body_params["repository"]["id"])
      commenter = conn.body_params["comment"]["user"]
      |> GitHub.User.from_json!()
      |> Syncer.sync_user()
      comment = conn.body_params["comment"]["body"]
      pr = GitHub.Pr.from_json!(conn.body_params["pull_request"])
      %Command{
        project: project,
        commenter: commenter,
        comment: comment,
        pr_xref: conn.body_params["pull_request"]["number"],
        pr: pr,
        patch: Syncer.sync_patch(project.id, pr)}
      |> Command.run()
    end
  end

  def do_webhook(conn, "github", "pull_request_review") do
    is_submitted = conn.body_params["action"] == "submitted"
    if is_submitted do
      project = Repo.get_by!(Project,
        repo_xref: conn.body_params["repository"]["id"])
      commenter = conn.body_params["review"]["user"]
      |> GitHub.User.from_json!()
      |> Syncer.sync_user()
      comment = conn.body_params["review"]["body"]
      pr = GitHub.Pr.from_json!(conn.body_params["pull_request"])
      %Command{
        project: project,
        commenter: commenter,
        comment: comment,
        pr_xref: conn.body_params["pull_request"]["number"],
        pr: pr,
        patch: Syncer.sync_patch(project.id, pr)}
      |> Command.run()
    end
  end

  def do_webhook(conn, "github", "status") do
    do_webhook_status(
      conn,
      conn.body_params["commit"]["commit"]["message"])
  end

  def do_webhook_status(conn, "Merge " <> _) do
    identifier = conn.body_params["context"]
    commit = conn.body_params["sha"]
    url = conn.body_params["target_url"]
    repo_xref = conn.body_params["repository"]["id"]
    state = GitHub.map_state_to_status(conn.body_params["state"])
    project = Repo.get_by!(Project, repo_xref: repo_xref)
    batcher = Batcher.Registry.get(project.id)
    Batcher.status(batcher, {commit, identifier, state, url})
  end

  def do_webhook_status(conn, "Try " <> _) do
    identifier = conn.body_params["context"]
    commit = conn.body_params["sha"]
    url = conn.body_params["target_url"]
    repo_xref = conn.body_params["repository"]["id"]
    state = GitHub.map_state_to_status(conn.body_params["state"])
    project = Repo.get_by!(Project, repo_xref: repo_xref)
    attemptor = Attemptor.Registry.get(project.id)
    Attemptor.status(attemptor, {commit, identifier, state, url})
  end

  def do_webhook_status(conn, "[ci skip] -bors-staging-tmp-" <> pr_xref) do
    identifier = conn.body_params["context"]
    err_msg = Batcher.Message.generate_staging_tmp_message(identifier)
    case err_msg do
      nil -> :ok
      err_msg ->
        conn.body_params["repository"]["id"]
        |> Project.installation_connection(Repo)
        |> GitHub.post_comment!(String.to_integer(pr_xref), err_msg)
    end
  end

  def do_webhook_status(_conn, _) do
    :ok
  end

  def do_webhook_pr(_conn, %{action: "opened", project: project}) do
    Project.ping!(project.id)
    :ok
  end

  def do_webhook_pr(_conn, %{action: "closed", project: project, patch: p}) do
    Project.ping!(project.id)
    Repo.update!(Patch.changeset(p, %{open: false}))
    :ok
  end

  def do_webhook_pr(_conn, %{action: "reopened", project: project, patch: p}) do
    Project.ping!(project.id)
    Repo.update!(Patch.changeset(p, %{open: true}))
    :ok
  end

  def do_webhook_pr(conn, %{action: "synchronize", project: pro, patch: p}) do
    batcher = Batcher.Registry.get(pro.id)
    Batcher.cancel(batcher, p.id)
    commit = conn.body_params["pull_request"]["head"]["sha"]
    Repo.update!(Patch.changeset(p, %{commit: commit}))
  end

  def do_webhook_pr(conn, %{action: "edited", patch: patch}) do
    %{
      "pull_request" => %{
        "title" => title,
        "body" => body,
        "base" => %{"ref" => base_ref},
      },
    } = conn.body_params
    Repo.update!(Patch.changeset(patch, %{
      title: title,
      body: body,
      into_branch: base_ref}))
  end

  def do_webhook_pr(_conn, %{action: action}) do
    Logger.info(["WebhookController: Got unknown action: ", action])
  end

  def create_installation_by_xref(installation_xref, sender) do
    i = case Repo.get_by(Installation, installation_xref: installation_xref) do
      nil -> Repo.insert!(%Installation{
        installation_xref: installation_xref
      })
      i -> i
    end
    {:installation, installation_xref}
    |> GitHub.get_installation_repos!()
    |> Enum.filter(&(@allow_private_repos || !&1.private))
    |> Enum.filter(& is_nil Repo.get_by(Project, repo_xref: &1.id))
    |> Enum.map(&%Project{repo_xref: &1.id, name: &1.name, installation: i})
    |> Enum.map(&Repo.insert!/1)
    |> Enum.map(&%LinkUserProject{user_id: sender.id, project_id: &1.id})
    |> Enum.map(&Repo.insert!/1)
    |> Enum.each(fn %LinkUserProject{project_id: project_id} ->
      Syncer.start_synchronize_project(project_id)
    end)
  end
end
