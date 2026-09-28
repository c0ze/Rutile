require "fileutils"
require "tmpdir"

# docs/wiki is the wiki's source. `rake wiki:publish` pushes it to the
# GitHub wikis: every page to Rutile's, and the runtime's pages, with their
# own Home and sidebar from docs/wiki/rustonrails, to RustOnRails'. Links
# between pages lose their `.md`; links into the repo become github.com
# links; a RustOnRails page's link to a page only Rutile's wiki has goes
# there.
WIKI_SOURCE = File.expand_path("../docs/wiki", __dir__)
WIKI_REPO = File.expand_path("..", __dir__)
RUNTIME_PAGES = %w[Runtime Configuration Sessions-and-Cookies Jobs Views Middleware-and-Errors Benchmarks].freeze

def wiki_page(text, here:, elsewhere: nil)
  text.gsub(/\]\(([^)\s]+)\)/) do
    target = Regexp.last_match(1)
    next "](#{target})" if target.start_with?("http", "#", "mailto:")

    path, anchor = target.split("#", 2)
    anchor = anchor ? "##{anchor}" : ""
    if path.end_with?(".md") && !path.include?("/")
      page = path.delete_suffix(".md")
      here.include?(page) ? "](#{page}#{anchor})" : "](#{elsewhere}/#{page}#{anchor})"
    else
      full = File.expand_path(path, WIKI_SOURCE)
      abort "#{target}: not a file in the repo" unless full.start_with?(WIKI_REPO) && File.exist?(full)
      "](https://github.com/c0ze/Rutile/#{File.directory?(full) ? "tree" : "blob"}/main/#{full.delete_prefix("#{WIKI_REPO}/")}#{anchor})"
    end
  end
end

def publish_wiki(repo, pages)
  Dir.mktmpdir do |dir|
    sh "git", "clone", "-q", "git@github.com:c0ze/#{repo}.wiki.git", dir
    Dir.glob("*.md", base: dir).each { File.delete(File.join(dir, _1)) }
    pages.each { |name, text| File.write(File.join(dir, "#{name}.md"), text) }
    Dir.chdir(dir) do
      sh "git", "add", "-A"
      next puts("#{repo} wiki: no changes") if system("git", "diff", "--cached", "--quiet")

      sh "git", "commit", "-q", "-m", "Published from docs/wiki"
      sh "git", "push", "-q", "origin", "HEAD"
    end
  end
end

namespace :wiki do
  desc "Publish docs/wiki to the Rutile and RustOnRails GitHub wikis"
  task :publish do
    read = ->(name, dir = WIKI_SOURCE) { File.read(File.join(dir, "#{name}.md"), encoding: "utf-8") }
    all = Dir.glob("*.md", base: WIKI_SOURCE).map { File.basename(_1, ".md") }
    publish_wiki("Rutile", all.to_h { [_1, wiki_page(read.(_1), here: all)] })
    runtime = File.join(WIKI_SOURCE, "rustonrails")
    own = Dir.glob("*.md", base: runtime).map { File.basename(_1, ".md") }
    here = RUNTIME_PAGES + own
    pages = RUNTIME_PAGES.to_h { [_1, wiki_page(read.(_1), here:, elsewhere: "https://github.com/c0ze/Rutile/wiki")] }
    own.each { pages[_1] = read.(_1, runtime) }
    publish_wiki("RustOnRails", pages)
  end
end
