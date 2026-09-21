# Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
# Copied into an ignored, source-pinned staging directory by prepare_libsignal.py.
Pod::Spec.new do |s|
  s.name = 'LibSignalClient'
  s.version = '0.102.3-bconnected.1'
  s.summary = 'BConnected personal libsignal, built locally from a pinned revision.'
  s.homepage = 'https://github.com/rolyv/BConnected-libsignal'
  s.license = { :type => 'AGPL-3.0-only', :file => 'LICENSE' }
  s.author = 'BConnected contributors and Signal Messenger LLC'
  s.source = { :git => 'https://github.com/rolyv/BConnected-libsignal.git', :commit => '77fb5f4f9e983ab66911eeadb4845e121b72597e' }
  s.swift_version = '5'
  s.platform = :ios, '15.0'
  s.source_files = ['swift/Sources/**/*.swift', 'swift/Sources/**/*.m']
  s.preserve_paths = ['swift/Sources/SignalFfi', 'native', 'provenance.json', 'source-lock.json']
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/swift/Sources/SignalFfi',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/swift/Sources/SignalFfi',
    'SWIFT_PACKAGE_NAME' => 'LibSignalClient',
    'LIBRARY_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/native/$(PLATFORM_NAME)"',
    'OTHER_LDFLAGS' => '"$(PODS_TARGET_SRCROOT)/native/$(PLATFORM_NAME)/libsignal_ffi.a"',
    'ARCHS' => 'arm64',
  }
  s.script_phase = {
    :name => 'Verify pinned BConnected libsignal inputs',
    :execution_position => :before_compile,
    :always_out_of_date => '1',
    :script => 'set -eu; /usr/bin/python3 "${PODS_ROOT}/../Scripts/bconnected/verify_libsignal.py" "${PODS_TARGET_SRCROOT}" --platform "${PLATFORM_NAME}"',
  }
end
