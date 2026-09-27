require "fileutils"
require "open3"
require "pathname"

module Rutile
  # `rutile package`: a crate `rutile build` wrote, made deployable. The
  # output directory builds on its own, offline: the crate, RustOnRails
  # beside it at the version it was built against (with that version's
  # Cargo.lock), every crate they use (`cargo vendor`), and a Dockerfile.
  # Packaging builds the release binary there; with an image tag it also
  # builds the container image, which needs no network to compile.
  module Package
    class Error < StandardError; end

    module_function

    # The release binary's path.
    def run(crate:, runtime:, out:, image: nil, log: $stdout)
      name = crate_name(crate)
      raise Error, "no Cargo.toml in #{runtime}; --runtime is the RustOnRails checkout" unless File.exist?(File.join(runtime, "Cargo.toml"))

      out = File.expand_path(out)
      { "the crate" => crate, "the runtime" => runtime }.each do |what, input|
        raise Error, "#{out} overlaps #{what} at #{input}; package somewhere apart from both" if overlap?(out, input)
      end
      raise Error, "#{out} is inside a Cargo workspace; package somewhere outside it" if in_workspace?(out)
      raise Error, "#{out} wasn't written by rutile package; refusing to replace it" unless replaceable?(out)

      FileUtils.rm_rf(%w[src vendor .cargo Cargo.toml Dockerfile .dockerignore].map { File.join(out, _1) })
      FileUtils.mkdir_p(out)
      FileUtils.cp_r(File.join(crate, "src"), out)
      vendor(runtime, File.join(out, "vendor/rustonrails"))
      lock = File.join(runtime, "Cargo.lock")
      FileUtils.cp(lock, out) if File.exist?(lock) && !File.exist?(File.join(out, "Cargo.lock"))
      File.write(File.join(out, "Cargo.toml"), cargo_toml(name))
      File.write(File.join(out, "Dockerfile"), dockerfile(name))
      File.write(File.join(out, ".dockerignore"), "target/\n")
      manifest = File.join(out, "Cargo.toml")
      run!(log, "cargo", "build", "--release", "--manifest-path", manifest)
      config = run!(log, "cargo", "vendor", "--locked", "--manifest-path", manifest, File.join(out, "vendor/crates"))
      FileUtils.mkdir_p(File.join(out, ".cargo"))
      File.write(File.join(out, ".cargo/config.toml"), config.sub(File.join(out, ""), ""))
      binary = File.join(out, "target/release", name)
      run!(log, "docker", "build", "--tag", image, out) if image
      binary
    end

    # Either path inside the other, or the same, after symlinks.
    def overlap?(a, b)
      a, b = [a, b].map { real(File.expand_path(_1)) }
      a == b || a.start_with?(File.join(b, "")) || b.start_with?(File.join(a, ""))
    end

    # A path's real form, through the part of it that exists.
    def real(path)
      return File.realpath(path) if File.exist?(path)

      parent = File.dirname(path)
      parent == path ? path : File.join(real(parent), File.basename(path))
    end

    # What packaging replaces is only ever its own: a missing or empty
    # directory, or one whose Cargo.toml it wrote.
    def replaceable?(out)
      return true unless File.directory?(out) && !Dir.empty?(out)

      manifest = File.join(out, "Cargo.toml")
      File.file?(manifest) && File.read(manifest).include?('rustonrails = { path = "vendor/rustonrails" }')
    end

    def crate_name(crate)
      manifest = File.join(crate, "Cargo.toml")
      raise Error, "no Cargo.toml in #{crate}; rutile build writes the crate" unless File.exist?(manifest)

      File.read(manifest)[/^\[package\][^\[]*?^name\s*=\s*"([^"]+)"/m, 1] or raise Error, "no package name in #{manifest}"
    end

    # The runtime's source and its own [package] and [dependencies]: not
    # its workspace or profiles, which only a workspace root may have.
    def vendor(runtime, into)
      manifest = File.join(runtime, "Cargo.toml")
      raise Error, "no Cargo.toml in #{runtime}; --runtime is the RustOnRails checkout" unless File.exist?(manifest)

      FileUtils.mkdir_p(into)
      FileUtils.cp_r(File.join(runtime, "src"), into)
      sections = File.read(manifest).split(/^(?=\[)/).select { _1.start_with?("[package]", "[dependencies]") }
      # A comment just before a dropped section is that section's.
      File.write(File.join(into, "Cargo.toml"), sections.map { _1.sub(/(\n#[^\n]*)+\n*\z/, "\n") }.join("\n").rstrip + "\n")
    end

    def cargo_toml(name)
      <<~TOML
        [package]
        name = "#{name}"
        version = "0.1.0"
        edition = "2024"
        publish = false

        [dependencies]
        rustonrails = { path = "vendor/rustonrails" }

        # Ruby promotes an overflowing Integer to a Bignum. This crate panics
        # (the server's 500) instead of wrapping, in release builds too.
        [profile.release]
        overflow-checks = true
      TOML
    end

    def dockerfile(name)
      <<~DOCKERFILE
        # Written by `rutile package`: the app as one binary on a slim image.
        # Run it with DATABASE_URL set; BIND and WORKERS have defaults here.
        FROM rust:1-slim-bookworm AS build
        WORKDIR /app
        COPY . .
        RUN cargo build --release --locked --offline && cp target/release/#{name} /#{name}

        FROM debian:bookworm-slim
        COPY --from=build /#{name} /usr/local/bin/#{name}
        ENV BIND=0.0.0.0:3000 WORKERS=5
        EXPOSE 3000
        USER nobody
        CMD ["#{name}"]
      DOCKERFILE
    end

    # Cargo would take the package for a workspace member it isn't.
    def in_workspace?(dir)
      Pathname(dir).ascend.drop(1).any? do |parent|
        manifest = parent.join("Cargo.toml")
        manifest.file? && manifest.read.match?(/^\[workspace\]/)
      end
    end

    # Its standard output.
    def run!(log, *command)
      log.puts command.join(" ")
      output, errors, status = Open3.capture3(*command)
      raise Error, "#{command.first(2).join(" ")} failed:\n#{(output + errors).lines.last(30).join}" unless status.success?

      output
    end
  end
end
