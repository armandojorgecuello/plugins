// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart=2.9

import 'dart:async';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

import 'common.dart';

/// A command to create an application that builds all in a single application.
class CreateAllPluginsAppCommand extends PluginCommand {
  /// Creates an instance of the builder command.
  CreateAllPluginsAppCommand(
    Directory packagesDir,
    FileSystem fileSystem, {
    this.pluginsRoot,
  }) : super(packagesDir, fileSystem) {
    pluginsRoot ??= fileSystem.currentDirectory;
    appDirectory = pluginsRoot.childDirectory('all_plugins');
  }

  /// The root directory of the plugin repository.
  Directory pluginsRoot;

  /// The location of the synthesized app project.
  Directory appDirectory;

  @override
  String get description =>
      'Generate Flutter app that includes all plugins in packages.';

  @override
  String get name => 'all-plugins-app';

  @override
  Future<void> run() async {
    final int exitCode = await _createApp();
    if (exitCode != 0) {
      throw ToolExit(exitCode);
    }

    await Future.wait(<Future<void>>[
      _genPubspecWithAllPlugins(),
      _updateAppGradle(),
      _updateManifest(),
    ]);
  }

  Future<int> _createApp() async {
    final io.ProcessResult result = io.Process.runSync(
      'flutter',
      <String>[
        'create',
        '--template=app',
        '--project-name=all_plugins',
        '--android-language=java',
        appDirectory.path,
      ],
    );

    print(result.stdout);
    print(result.stderr);
    return result.exitCode;
  }

  Future<void> _updateAppGradle() async {
    final File gradleFile = appDirectory
        .childDirectory('android')
        .childDirectory('app')
        .childFile('build.gradle');
    if (!gradleFile.existsSync()) {
      throw ToolExit(64);
    }

    final StringBuffer newGradle = StringBuffer();
    for (final String line in gradleFile.readAsLinesSync()) {
      newGradle.writeln(line);
      if (line.contains('defaultConfig {')) {
        newGradle.writeln('        multiDexEnabled true');
      } else if (line.contains('dependencies {')) {
        newGradle.writeln(
          '    implementation \'com.google.guava:guava:27.0.1-android\'\n',
        );
        // Tests for https://github.com/flutter/flutter/issues/43383
        newGradle.writeln(
          "    implementation 'androidx.lifecycle:lifecycle-runtime:2.2.0-rc01'\n",
        );
      }
    }
    gradleFile.writeAsStringSync(newGradle.toString());
  }

  Future<void> _updateManifest() async {
    final File manifestFile = appDirectory
        .childDirectory('android')
        .childDirectory('app')
        .childDirectory('src')
        .childDirectory('main')
        .childFile('AndroidManifest.xml');
    if (!manifestFile.existsSync()) {
      throw ToolExit(64);
    }

    final StringBuffer newManifest = StringBuffer();
    for (final String line in manifestFile.readAsLinesSync()) {
      if (line.contains('package="com.example.all_plugins"')) {
        newManifest
          ..writeln('package="com.example.all_plugins"')
          ..writeln('xmlns:tools="http://schemas.android.com/tools">')
          ..writeln()
          ..writeln(
            '<uses-sdk tools:overrideLibrary="io.flutter.plugins.camera"/>',
          );
      } else {
        newManifest.writeln(line);
      }
    }
    manifestFile.writeAsStringSync(newManifest.toString());
  }

  Future<void> _genPubspecWithAllPlugins() async {
    final Map<String, PathDependency> pluginDeps =
        await _getValidPathDependencies();
    final Pubspec pubspec = Pubspec(
      'all_plugins',
      description: 'Flutter app containing all 1st party plugins.',
      version: Version.parse('1.0.0+1'),
      environment: <String, VersionConstraint>{
        'sdk': VersionConstraint.compatibleWith(
          Version.parse('2.12.0'),
        ),
      },
      dependencies: <String, Dependency>{
        'flutter': SdkDependency('flutter'),
      }..addAll(pluginDeps),
      devDependencies: <String, Dependency>{
        'flutter_test': SdkDependency('flutter'),
      },
      dependencyOverrides: pluginDeps,
    );
    final File pubspecFile = appDirectory.childFile('pubspec.yaml');
    pubspecFile.writeAsStringSync(_pubspecToString(pubspec));
  }

  Future<Map<String, PathDependency>> _getValidPathDependencies() async {
    final Map<String, PathDependency> pathDependencies =
        <String, PathDependency>{};

    await for (final Directory package in getPlugins()) {
      final String pluginName = package.path.split('/').last;
      final File pubspecFile =
          fileSystem.file(p.join(package.path, 'pubspec.yaml'));
      final Pubspec pubspec = Pubspec.parse(pubspecFile.readAsStringSync());

      if (pubspec.publishTo != 'none') {
        pathDependencies[pluginName] = PathDependency(package.path);
      }
    }
    return pathDependencies;
  }

  String _pubspecToString(Pubspec pubspec) {
    return '''
### Generated file. Do not edit. Run `pub global run flutter_plugin_tools gen-pubspec` to update.
name: ${pubspec.name}
description: ${pubspec.description}

version: ${pubspec.version}

environment:${_pubspecMapString(pubspec.environment)}

dependencies:${_pubspecMapString(pubspec.dependencies)}

dependency_overrides:${_pubspecMapString(pubspec.dependencyOverrides)}

dev_dependencies:${_pubspecMapString(pubspec.devDependencies)}
###''';
  }

  String _pubspecMapString(Map<String, dynamic> values) {
    final StringBuffer buffer = StringBuffer();

    for (final MapEntry<String, dynamic> entry in values.entries) {
      buffer.writeln();
      if (entry.value is VersionConstraint) {
        buffer.write('  ${entry.key}: ${entry.value}');
      } else if (entry.value is SdkDependency) {
        final SdkDependency dep = entry.value as SdkDependency;
        buffer.write('  ${entry.key}: \n    sdk: ${dep.sdk}');
      } else if (entry.value is PathDependency) {
        final PathDependency dep = entry.value as PathDependency;
        buffer.write('  ${entry.key}: \n    path: ${dep.path}');
      } else {
        throw UnimplementedError(
          'Not available for type: ${entry.value.runtimeType}',
        );
      }
    }

    return buffer.toString();
  }
}
