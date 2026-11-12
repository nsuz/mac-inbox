import Foundation

extension GitHub.Notification {
    // The API gives CheckSuite threads no URL, so the runs are found through the title GitHub writes,
    // such as "CI workflow run, Attempt #2 failed for main branch". The result is left out of the
    // search: a rerun can change it, and the run would then drop out of a search narrowed by it.
    var workflowRunsPage: URL? {
        // Captures the workflow name before " workflow run", skips an optional ", Attempt #N" and
        // the result up to the last " for ", then captures the branch name before the closing " branch".
        let title = /(?<workflow>.+?) workflow run(?:, Attempt #\d+)? .+? for (?<branch>.+) branch/
        guard subject.type == "CheckSuite", let match = subject.title.wholeMatch(of: title) else { return nil }

        var components = URLComponents(url: repository.htmlURL.appending(path: "actions"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: #"workflow:"\#(match.workflow)" branch:\#(match.branch)"#)]
        return components?.url
    }
}
