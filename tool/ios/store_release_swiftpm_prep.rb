# frozen_string_literal: true

require "json"
require "pathname"
require "tempfile"
require "uri"

# Validates the iOS SwiftPM inputs consumed by a Maaso build, keeps Firebase in
# CocoaPods with ML Kit and location in CocoaPods for its foreground-only flag,
# and raises known Flutter-generated deployment targets before Xcode resolves them.
module MaasoIosSwiftpmPrep
  class Error < StandardError; end

  REQUIRED_IOS_VERSION = "16.4"
  FLUTTER_GENERATED_IOS_VERSION = "13.0"
  FLUTTER_GENERATED_IOS_VERSIONS = [FLUTTER_GENERATED_IOS_VERSION, "15.0"].freeze
  LLAMADART_PACKAGE_NAME = "llamadart_llama_cpp_flutter"
  LLAMADART_GENERATED_PACKAGE_PATH =
    "../.packages/llamadart_llama_cpp_flutter-0.0.11"
  COCOAPODS_OWNED_PACKAGES = {
    "firebase_core" => "firebase-core",
    "firebase_messaging" => "firebase-messaging",
    "geolocator_apple" => "geolocator-apple",
  }.freeze

  RUNNER_PROJECT_RELATIVE_PATH = "ios/Runner.xcodeproj/project.pbxproj"
  PACKAGE_CONFIG_RELATIVE_PATH = ".dart_tool/package_config.json"
  GENERATED_PACKAGE_RELATIVE_PATH =
    "ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
  FLUTTER_FRAMEWORK_RELATIVE_PATH =
    "ios/Flutter/ephemeral/Packages/.packages/FlutterFramework/Package.swift"
  LLAMADART_MANIFEST_RELATIVE_PATH =
    "darwin/llamadart_llama_cpp_flutter/Package.swift"

  MAX_RUNNER_PROJECT_BYTES = 4 * 1024 * 1024
  MAX_PACKAGE_CONFIG_BYTES = 4 * 1024 * 1024
  MAX_GENERATED_PACKAGE_BYTES = 1024 * 1024
  MAX_DEPENDENCY_MANIFEST_BYTES = 512 * 1024

  GENERATED_PREFIX = <<~'SWIFT'
    // swift-tools-version: 5.9
    // The swift-tools-version declares the minimum version of Swift required to build this package.
    //
    // Generated file. Do not edit.
    //

    import PackageDescription

    let package = Package(
        name: "FlutterGeneratedPluginSwiftPackage",
        platforms: [
  SWIFT

  GENERATED_AFTER_PLATFORM = [
    "    ],",
    "    products: [",
    '        .library(name: "FlutterGeneratedPluginSwiftPackage", type: .static, targets: ["FlutterGeneratedPluginSwiftPackage"])',
    "    ],",
    "    dependencies: [",
    "",
  ].join("\n").freeze

  GENERATED_BETWEEN_DEPENDENCIES_AND_PRODUCTS = [
    "    ],",
    "    targets: [",
    "        .target(",
    '            name: "FlutterGeneratedPluginSwiftPackage",',
    "            dependencies: [",
    "",
  ].join("\n").freeze

  GENERATED_SUFFIX = [
    "            ]",
    "        )",
    "    ]",
    ")",
    "",
  ].join("\n").freeze

  PACKAGE_ROW_SOURCE =
    '        \.package\(name: "[A-Za-z][A-Za-z0-9_]*", path: "\.\./\.packages/[A-Za-z0-9][A-Za-z0-9_.+\-]*"\),?\n'
  PRODUCT_ROW_SOURCE =
    '                \.product\(name: "[A-Za-z0-9][A-Za-z0-9_.+\-]*", package: "[A-Za-z][A-Za-z0-9_]*"\),?\n'
  GENERATED_PACKAGE_PATTERN = Regexp.new(
    "\\A#{Regexp.escape(GENERATED_PREFIX)}" \
    '        \.iOS\("(?<ios_version>[^"\r\n]+)"\)\n' \
    "#{Regexp.escape(GENERATED_AFTER_PLATFORM)}" \
    "(?<package_rows>(?:#{PACKAGE_ROW_SOURCE})+)" \
    "#{Regexp.escape(GENERATED_BETWEEN_DEPENDENCIES_AND_PRODUCTS)}" \
    "(?<product_rows>(?:#{PRODUCT_ROW_SOURCE})+)" \
    "#{Regexp.escape(GENERATED_SUFFIX)}\\z",
  )
  PACKAGE_ROW_PATTERN = Regexp.new(
    '\A        \.package\(name: "([A-Za-z][A-Za-z0-9_]*)", ' \
    'path: "\.\./\.packages/([A-Za-z0-9][A-Za-z0-9_.+\-]*)"\)(,?)\z',
  )
  PRODUCT_ROW_PATTERN = Regexp.new(
    '\A                \.product\(name: "([A-Za-z0-9][A-Za-z0-9_.+\-]*)", ' \
    'package: "([A-Za-z][A-Za-z0-9_]*)"\)(,?)\z',
  )

  EXPECTED_FLUTTER_FRAMEWORK_MANIFEST = [
    "// swift-tools-version: 5.9",
    "// The swift-tools-version declares the minimum version of Swift required to build this package.",
    "//",
    "// Generated file. Do not edit.",
    "//",
    "",
    "import PackageDescription",
    "",
    "let package = Package(",
    '    name: "FlutterFramework",',
    "    products: [",
    '        .library(name: "FlutterFramework", targets: ["FlutterFramework"])',
    "    ],",
    "    dependencies: [",
    "        ",
    "    ],",
    "    targets: [",
    "        .target(",
    '            name: "FlutterFramework"',
    "        )",
    "    ]",
    ")",
    "",
  ].join("\n").freeze

  module_function

  def prepare!(repo_root:)
    root = canonical_directory!(repo_root, "repository root")
    verify_runner_deployment_target!(root)
    verify_llamadart_deployment_target!(root)
    verify_flutter_framework!(root)

    generated = read_bounded_regular_file!(
      root: root,
      relative: GENERATED_PACKAGE_RELATIVE_PATH,
      maximum_bytes: MAX_GENERATED_PACKAGE_BYTES,
      label: "Flutter generated plugin package manifest",
    )
    updated = remove_cocoapods_owned_packages!(generated.fetch(:content))
    current_version = validate_generated_package!(updated)

    if FLUTTER_GENERATED_IOS_VERSIONS.include?(current_version)
      from = %(        .iOS("#{current_version}")\n)
      to = %(        .iOS("#{REQUIRED_IOS_VERSION}")\n)
      unless updated.scan(from).length == 1
        raise Error, "Flutter generated plugin package has an ambiguous iOS platform declaration"
      end
      updated = updated.sub(from, to)
    end

    unless validate_generated_package!(updated) == REQUIRED_IOS_VERSION
      raise Error, "prepared Flutter generated plugin package did not validate"
    end
    verify_cocoapods_owned_packages_absent!(updated)
    return :unchanged if updated == generated.fetch(:content)

    atomic_replace!(
      root: root,
      relative: GENERATED_PACKAGE_RELATIVE_PATH,
      bytes: updated,
      original_stat: generated.fetch(:stat),
    )

    persisted = read_bounded_regular_file!(
      root: root,
      relative: GENERATED_PACKAGE_RELATIVE_PATH,
      maximum_bytes: MAX_GENERATED_PACKAGE_BYTES,
      label: "prepared Flutter generated plugin package manifest",
    )
    unless persisted.fetch(:content) == updated &&
           validate_generated_package!(persisted.fetch(:content)) == REQUIRED_IOS_VERSION
      raise Error, "prepared Flutter generated plugin package was not persisted exactly"
    end
    verify_cocoapods_owned_packages_absent!(persisted.fetch(:content))

    :updated
  end

  def verify_runner_deployment_target!(root)
    project = read_bounded_regular_file!(
      root: root,
      relative: RUNNER_PROJECT_RELATIVE_PATH,
      maximum_bytes: MAX_RUNNER_PROJECT_BYTES,
      label: "Runner Xcode project",
    ).fetch(:content)

    runner_target_anchor = 'Build configuration list for PBXNativeTarget "Runner"'
    runner_project_anchor = 'Build configuration list for PBXProject "Runner"'
    unless project.scan(runner_target_anchor).length == 2 &&
           project.scan(runner_project_anchor).length == 2 &&
           project.scan(/^\s*name = Runner;$/).length == 1 &&
           project.scan(/^\s*productName = Runner;$/).length == 1
      raise Error, "Runner Xcode project does not have the expected target/configuration shape"
    end

    target_mentions = project.scan("IPHONEOS_DEPLOYMENT_TARGET")
    versions = project.scan(/^\s*IPHONEOS_DEPLOYMENT_TARGET = ([^;\s]+);$/).flatten
    unless target_mentions.length == 3 && versions == [REQUIRED_IOS_VERSION] * 3
      raise Error, "Runner Xcode deployment target must be exactly #{REQUIRED_IOS_VERSION}"
    end
    true
  end

  def verify_llamadart_deployment_target!(root)
    package_root = llamadart_package_root!(root)
    manifest = read_bounded_regular_file!(
      root: package_root,
      relative: LLAMADART_MANIFEST_RELATIVE_PATH,
      maximum_bytes: MAX_DEPENDENCY_MANIFEST_BYTES,
      label: "llamadart Swift package manifest",
    ).fetch(:content)

    package_anchor = [
      "let package = Package(",
      '    name: "llamadart_llama_cpp_flutter",',
      "    platforms: [",
      "",
    ].join("\n")
    unless manifest.scan(package_anchor).length == 1 &&
           manifest.scan(/^let package = Package\($/).length == 1 &&
           manifest.scan(/^\s*platforms: \[$/).length == 1
      raise Error, "llamadart Swift package does not have the expected package shape"
    end

    ios_mentions = manifest.scan(/\.iOS\(/)
    versions = manifest.scan(/^\s{8}\.iOS\("([^"\r\n]+)"\),$/).flatten
    unless ios_mentions.length == 1 && versions == [REQUIRED_IOS_VERSION]
      raise Error, "llamadart Swift package iOS version must be exactly #{REQUIRED_IOS_VERSION}"
    end
    true
  end

  def verify_flutter_framework!(root)
    manifest = read_bounded_regular_file!(
      root: root,
      relative: FLUTTER_FRAMEWORK_RELATIVE_PATH,
      maximum_bytes: MAX_DEPENDENCY_MANIFEST_BYTES,
      label: "FlutterFramework local package manifest",
    ).fetch(:content)
    unless manifest == EXPECTED_FLUTTER_FRAMEWORK_MANIFEST
      raise Error, "FlutterFramework local package manifest has an unknown generated shape"
    end
    true
  end

  def validate_generated_package!(content)
    ios_mentions = content.scan(/\.iOS\(/)
    unless ios_mentions.length == 1 && content.scan(/^\s*platforms: \[$/).length == 1
      raise Error, "Flutter generated plugin package must contain exactly one iOS platform"
    end

    match = GENERATED_PACKAGE_PATTERN.match(content)
    unless match
      raise Error, "Flutter generated plugin package has an unknown generated shape"
    end

    packages = parse_package_rows!(match[:package_rows])
    products = parse_product_rows!(match[:product_rows])
    package_names = packages.map { |entry| entry.fetch(:name) }
    product_packages = products.map { |entry| entry.fetch(:package) }
    unless package_names.uniq.length == package_names.length &&
           product_packages.uniq.length == product_packages.length &&
           package_names == product_packages
      raise Error, "Flutter generated plugin package dependencies are ambiguous"
    end

    non_framework_names = package_names.reject { |name| name == "FlutterFramework" }
    unless non_framework_names == non_framework_names.sort
      raise Error, "Flutter generated plugin package dependencies are not canonical"
    end

    packages.each do |entry|
      next if entry.fetch(:name) == "FlutterFramework"

      leaf = entry.fetch(:path)
      name = entry.fetch(:name)
      unless leaf == name || leaf.start_with?("#{name}-")
        raise Error, "Flutter generated plugin package dependency path is not canonical"
      end
    end

    expected_framework_package = {
      name: "FlutterFramework",
      path: "FlutterFramework",
      comma: "",
    }
    expected_framework_product = {
      name: "FlutterFramework",
      package: "FlutterFramework",
      comma: "",
    }
    unless packages.last == expected_framework_package &&
           products.last == expected_framework_product
      raise Error, "FlutterFramework local package/product/target wiring is missing"
    end

    llama_package = packages.find { |entry| entry.fetch(:name) == LLAMADART_PACKAGE_NAME }
    llama_product = products.find { |entry| entry.fetch(:package) == LLAMADART_PACKAGE_NAME }
    unless llama_package&.fetch(:path) == File.basename(LLAMADART_GENERATED_PACKAGE_PATH) &&
           llama_product&.fetch(:name) == "llamadart-llama-cpp-flutter"
      raise Error, "llamadart generated package/product wiring is missing"
    end

    version = match[:ios_version]
    unless (FLUTTER_GENERATED_IOS_VERSIONS + [REQUIRED_IOS_VERSION]).include?(version)
      raise Error,
            "Flutter generated plugin package iOS version must be " \
            "#{FLUTTER_GENERATED_IOS_VERSIONS.join(', ')} or #{REQUIRED_IOS_VERSION}"
    end
    version
  end

  def remove_cocoapods_owned_packages!(content)
    updated = content
    COCOAPODS_OWNED_PACKAGES.each do |package_name, product_name|
      package_mentions = content.scan(/\.package\(name: "#{Regexp.escape(package_name)}"/).length
      product_mentions = content.scan(/\.product\(name: "[^"]+", package: "#{Regexp.escape(package_name)}"\)/).length
      unless package_mentions == product_mentions && [0, 1].include?(package_mentions)
        raise Error, "Flutter generated #{package_name} package/product wiring is ambiguous"
      end
      next if package_mentions.zero?

      package_row = /^        \.package\(name: "#{Regexp.escape(package_name)}", path: "\.\.\/\.packages\/#{Regexp.escape(package_name)}-[A-Za-z0-9][A-Za-z0-9_.+\-]*"\),\n/
      product_row = /^                \.product\(name: "#{Regexp.escape(product_name)}", package: "#{Regexp.escape(package_name)}"\),\n/
      unless updated.scan(package_row).length == 1 && updated.scan(product_row).length == 1
        raise Error, "Flutter generated #{package_name} rows have an unknown shape"
      end
      updated = updated.sub(package_row, "").sub(product_row, "")
    end
    updated
  end

  def verify_cocoapods_owned_packages_absent!(content)
    COCOAPODS_OWNED_PACKAGES.each_key do |package_name|
      if content.include?(%(package: "#{package_name}")) ||
         content.include?(%(name: "#{package_name}"))
        raise Error, "Flutter generated package still contains CocoaPods-owned #{package_name}"
      end
    end
    true
  end

  def parse_package_rows!(rows)
    parse_rows!(rows, PACKAGE_ROW_PATTERN, "package").map do |captures|
      { name: captures.fetch(0), path: captures.fetch(1), comma: captures.fetch(2) }
    end
  end

  def parse_product_rows!(rows)
    parse_rows!(rows, PRODUCT_ROW_PATTERN, "product").map do |captures|
      { name: captures.fetch(0), package: captures.fetch(1), comma: captures.fetch(2) }
    end
  end

  def parse_rows!(rows, pattern, label)
    lines = rows.lines(chomp: true)
    raise Error, "Flutter generated plugin package has no #{label} rows" if lines.empty?

    captures = lines.map do |line|
      match = pattern.match(line)
      raise Error, "Flutter generated plugin package has an invalid #{label} row" unless match

      match.captures
    end
    unless captures.each_with_index.all? do |values, index|
      values.last == (index == captures.length - 1 ? "" : ",")
    end
      raise Error, "Flutter generated plugin package #{label} commas are not canonical"
    end
    captures
  end

  def llamadart_package_root!(root)
    config_bytes = read_bounded_regular_file!(
      root: root,
      relative: PACKAGE_CONFIG_RELATIVE_PATH,
      maximum_bytes: MAX_PACKAGE_CONFIG_BYTES,
      label: "Dart package configuration",
    ).fetch(:content)
    config = JSON.parse(config_bytes)
    packages = config.fetch("packages")
    unless packages.is_a?(Array)
      raise Error, "Dart package configuration packages must be an array"
    end

    matches = packages.select do |entry|
      entry.is_a?(Hash) && entry["name"] == LLAMADART_PACKAGE_NAME
    end
    unless matches.length == 1
      raise Error, "Dart package configuration must contain exactly one llamadart package"
    end

    root_uri = matches.first.fetch("rootUri")
    uri = URI.parse(root_uri)
    unless uri.scheme == "file" && (uri.host.nil? || uri.host.empty?) &&
           uri.userinfo.nil? && uri.port.nil? && uri.query.nil? && uri.fragment.nil?
      raise Error, "llamadart package root must be a local canonical file URI"
    end

    decoded_path = URI::DEFAULT_PARSER.unescape(uri.path.to_s)
    unless Pathname.new(decoded_path).absolute? && !decoded_path.include?("\0")
      raise Error, "llamadart package root file URI must contain an absolute path"
    end
    canonical_directory!(decoded_path, "llamadart package root")
  rescue JSON::ParserError, KeyError, URI::InvalidURIError => error
    raise Error, "invalid Dart package configuration: #{error.message}"
  end

  def read_bounded_regular_file!(root:, relative:, maximum_bytes:, label:)
    validate_relative_path!(relative, label)
    assert_no_symlink_components!(root, relative, label)
    path = File.join(root, relative)
    before = File.lstat(path)
    raise Error, "#{label} must be a regular file" unless before.file?
    unless before.size.positive? && before.size <= maximum_bytes
      raise Error, "#{label} exceeds the accepted size bounds"
    end

    bytes = nil
    File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
      file.binmode
      opened = file.stat
      raise Error, "#{label} changed before it could be read" unless same_snapshot?(before, opened)

      bytes = file.read(maximum_bytes + 1)
      after = file.stat
      raise Error, "#{label} changed while it was being read" unless same_snapshot?(opened, after)
    end
    raise Error, "#{label} exceeds the accepted size bounds" if bytes.bytesize > maximum_bytes

    content = bytes.dup.force_encoding(Encoding::UTF_8)
    unless content.valid_encoding? && !content.include?("\0") &&
           !content.include?("\r") && content.end_with?("\n")
      raise Error, "#{label} must be canonical UTF-8 text with LF line endings"
    end
    { content: content, stat: before, path: path }
  rescue Errno::ENOENT
    raise Error, "required #{label} is missing"
  rescue Errno::ELOOP
    raise Error, "#{label} must not be a symlink"
  rescue SystemCallError => error
    raise Error, "unable to read #{label}: #{error.message}"
  end

  def atomic_replace!(root:, relative:, bytes:, original_stat:)
    validate_relative_path!(relative, "Flutter generated plugin package manifest")
    assert_no_symlink_components!(root, relative, "Flutter generated plugin package manifest")
    destination = File.join(root, relative)
    parent = File.dirname(destination)
    current = File.lstat(destination)
    unless current.file? && same_snapshot?(original_stat, current)
      raise Error, "Flutter generated plugin package changed before the atomic update"
    end

    Tempfile.create([".maaso-swiftpm-prep-", ".tmp"], parent) do |temporary|
      temporary.binmode
      temporary.write(bytes)
      temporary.flush
      temporary.fsync
      File.chmod(original_stat.mode & 0o777, temporary.path)

      assert_no_symlink_components!(root, relative, "Flutter generated plugin package manifest")
      latest = File.lstat(destination)
      unless latest.file? && same_snapshot?(original_stat, latest)
        raise Error, "Flutter generated plugin package changed before the atomic update"
      end
      File.rename(temporary.path, destination)
    end
    true
  rescue Errno::ENOENT
    raise Error, "Flutter generated plugin package disappeared before the atomic update"
  rescue SystemCallError => error
    raise Error, "unable to atomically prepare Flutter generated plugin package: #{error.message}"
  end

  def canonical_directory!(path, label)
    unless path.is_a?(String) && !path.empty? && path.valid_encoding? &&
           !path.include?("\0") && Pathname.new(path).absolute?
      raise Error, "#{label} path must be an absolute canonical path"
    end

    expanded = File.expand_path(path)
    real = File.realpath(expanded)
    raise Error, "#{label} path is not canonical" unless expanded == real

    assert_absolute_no_symlink_components!(real, label)
    stat = File.lstat(real)
    raise Error, "#{label} must be a directory" unless stat.directory?
    real
  rescue SystemCallError => error
    raise Error, "unable to resolve #{label}: #{error.message}"
  end

  def assert_absolute_no_symlink_components!(absolute, label)
    current = File::SEPARATOR
    Pathname.new(absolute).each_filename do |component|
      current = File.join(current, component)
      stat = File.lstat(current)
      raise Error, "#{label} path must not contain symlinks" if stat.symlink?
      raise Error, "#{label} path has a non-directory component" unless stat.directory?
    end
  end

  def assert_no_symlink_components!(root, relative, label)
    current = root
    relative.split("/").each_with_index do |component, index|
      current = File.join(current, component)
      stat = File.lstat(current)
      raise Error, "#{label} must not contain symlinks" if stat.symlink?
      next if index == relative.split("/").length - 1

      raise Error, "#{label} has a non-directory ancestor" unless stat.directory?
    end
  rescue Errno::ENOENT
    raise Error, "required #{label} is missing"
  end

  def validate_relative_path!(relative, label)
    unless relative.is_a?(String) && !relative.empty? && relative.valid_encoding? &&
           !relative.start_with?("/") && !relative.include?("\0") &&
           !relative.match?(/[\r\n]/) && Pathname.new(relative).cleanpath.to_s == relative &&
           relative.split("/").none? { |component| component.empty? || component == "." || component == ".." }
      raise Error, "#{label} path is not canonical"
    end
  end

  def same_snapshot?(left, right)
    left.dev == right.dev && left.ino == right.ino && left.size == right.size &&
      left.mtime == right.mtime && left.mtime.nsec == right.mtime.nsec &&
      left.ctime == right.ctime && left.ctime.nsec == right.ctime.nsec
  end
end
