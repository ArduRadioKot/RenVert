#!/usr/bin/env python3
import os
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJ = ROOT / "Renvert.xcodeproj"

def rid():
    return uuid.uuid4().hex[:24].upper()

core_files = sorted((ROOT / "Sources/RenvertCore").glob("*.swift"))
app_files = sorted((ROOT / "Sources/Renvert").rglob("*.swift"))
test_files = sorted((ROOT / "Tests/RenvertCoreTests").glob("*.swift"))

ids = {path: rid() for path in core_files + app_files + test_files}
ids.update({
    "project": rid(),
    "app_target": rid(),
    "test_target": rid(),
    "app_product": rid(),
    "test_product": rid(),
    "core_group": rid(),
    "app_group": rid(),
    "test_group": rid(),
    "src_group": rid(),
    "products": rid(),
    "main_group": rid(),
    "app_sources": rid(),
    "test_sources": rid(),
    "app_resources": rid(),
    "frameworks": rid(),
    "app_config_list": rid(),
    "test_config_list": rid(),
    "proj_config_list": rid(),
    "app_debug": rid(),
    "app_release": rid(),
    "test_debug": rid(),
    "test_release": rid(),
    "proj_debug": rid(),
    "proj_release": rid(),
    "plist": rid(),
    "entitlements": rid(),
    "xcstrings": rid(),
    "infoplist_strings": rid(),
    "assets": rid(),
})

def fileref(path, last=None, ut="sourcecode.swift"):
    return f'\t\t{ids[path]} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = {ut}; path = {path.name}; sourceTree = "<group>"; }};'

file_refs = []
for path in core_files + app_files + test_files:
    file_refs.append(fileref(path))
file_refs.append(f'\t\t{ids["app_product"]} /* Renvert.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Renvert.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
file_refs.append(f'\t\t{ids["test_product"]} /* RenvertTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = RenvertTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
file_refs.append(f'\t\t{ids["plist"]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
file_refs.append(f'\t\t{ids["entitlements"]} /* Renvert.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Renvert.entitlements; sourceTree = "<group>"; }};')
file_refs.append(f'\t\t{ids["xcstrings"]} /* Localizable.xcstrings */ = {{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = "<group>"; }};')
file_refs.append(f'\t\t{ids["infoplist_strings"]} /* InfoPlist.xcstrings */ = {{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = InfoPlist.xcstrings; sourceTree = "<group>"; }};')
file_refs.append(f'\t\t{ids["assets"]} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')

def children(paths):
    return "".join(f"\t\t\t\t{ids[p]} /* {p.name} */,\n" for p in paths)

app_build = "".join(f"\t\t\t\t{rid()} /* {p.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ids[p]}; }};\n" for p in core_files + app_files)
# Need stable build file ids
build_ids = {}
build_entries = []
for path in core_files + app_files:
    bid = rid()
    build_ids[path] = bid
    build_entries.append(f"\t\t{bid} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ids[path]} /* {path.name} */; }};")
test_build_ids = {}
for path in core_files + test_files:
    bid = rid()
    test_build_ids[path] = bid
    build_entries.append(f"\t\t{bid} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ids[path]} /* {path.name} */; }};")
res_xc = rid()
res_assets = rid()
res_infoplist = rid()
build_entries.append(f"\t\t{res_xc} /* Localizable.xcstrings in Resources */ = {{isa = PBXBuildFile; fileRef = {ids['xcstrings']} /* Localizable.xcstrings */; }};")
build_entries.append(f"\t\t{res_infoplist} /* InfoPlist.xcstrings in Resources */ = {{isa = PBXBuildFile; fileRef = {ids['infoplist_strings']} /* InfoPlist.xcstrings */; }};")
build_entries.append(f"\t\t{res_assets} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ids['assets']} /* Assets.xcassets */; }};")

app_source_list = "".join(f"\t\t\t\t{build_ids[p]} /* {p.name} in Sources */,\n" for p in core_files + app_files)
test_source_list = "".join(f"\t\t\t\t{test_build_ids[p]} /* {p.name} in Sources */,\n" for p in core_files + test_files)

common = """
CLANG_ENABLE_MODULES = YES;
CLANG_ENABLE_OBJC_ARC = YES;
CODE_SIGN_STYLE = Automatic;
COMBINE_HIDPI_IMAGES = YES;
ENABLE_HARDENED_RUNTIME = YES;
MACOSX_DEPLOYMENT_TARGET = 14.0;
PRODUCT_BUNDLE_IDENTIFIER = app.renvert.macos;
SDKROOT = macosx;
SWIFT_VERSION = 5.0;
ALWAYS_SEARCH_USER_PATHS = NO;
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
"""

pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{os.linesep.join(build_entries)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{os.linesep.join(file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{ids['frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{ids['main_group']} = {{
			isa = PBXGroup;
			children = (
				{ids['src_group']} /* Sources */,
				{ids['test_group']} /* Tests */,
				{ids['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids['src_group']} /* Sources */ = {{
			isa = PBXGroup;
			children = (
				{ids['core_group']} /* RenvertCore */,
				{ids['app_group']} /* Renvert */,
			);
			path = Sources;
			sourceTree = "<group>";
		}};
		{ids['core_group']} /* RenvertCore */ = {{
			isa = PBXGroup;
			children = (
{children(core_files)}			);
			path = RenvertCore;
			sourceTree = "<group>";
		}};
		{ids['app_group']} /* Renvert */ = {{
			isa = PBXGroup;
			children = (
{children(app_files)}				{ids['plist']} /* Info.plist */,
				{ids['entitlements']} /* Renvert.entitlements */,
				{ids['xcstrings']} /* Localizable.xcstrings */,
				{ids['infoplist_strings']} /* InfoPlist.xcstrings */,
				{ids['assets']} /* Assets.xcassets */,
			);
			path = Renvert;
			sourceTree = "<group>";
		}};
		{ids['test_group']} /* Tests */ = {{
			isa = PBXGroup;
			children = (
{children(test_files)}			);
			path = ../Tests/RenvertCoreTests;
			sourceTree = "<group>";
		}};
		{ids['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids['app_product']} /* Renvert.app */,
				{ids['test_product']} /* RenvertTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ids['app_target']} /* Renvert */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['app_config_list']} /* Build configuration list for PBXNativeTarget "Renvert" */;
			buildPhases = (
				{ids['app_sources']} /* Sources */,
				{ids['frameworks']} /* Frameworks */,
				{ids['app_resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = Renvert;
			productName = Renvert;
			productReference = {ids['app_product']} /* Renvert.app */;
			productType = "com.apple.product-type.application";
		}};
		{ids['test_target']} /* RenvertTests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['test_config_list']} /* Build configuration list for PBXNativeTarget "RenvertTests" */;
			buildPhases = (
				{ids['test_sources']} /* Sources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = RenvertTests;
			productName = RenvertTests;
			productReference = {ids['test_product']} /* RenvertTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{ids['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
			}};
			buildConfigurationList = {ids['proj_config_list']} /* Build configuration list for PBXProject "Renvert" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				ru,
				Base,
			);
			mainGroup = {ids['main_group']};
			productRefGroup = {ids['products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['app_target']} /* Renvert */,
				{ids['test_target']} /* RenvertTests */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{ids['app_resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{res_xc} /* Localizable.xcstrings in Resources */,
				{res_infoplist} /* InfoPlist.xcstrings in Resources */,
				{res_assets} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{ids['app_sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{app_source_list}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{ids['test_sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{test_source_list}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{ids['proj_debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				{common}
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{ids['proj_release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				{common}
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};
		{ids['app_debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = Sources/Renvert/Renvert.entitlements;
				CODE_SIGN_IDENTITY = "-";
				COMBINE_HIDPI_IMAGES = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Sources/Renvert/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
				PRODUCT_NAME = Renvert;
				SWIFT_EMIT_LOC_STRINGS = YES;
			}};
			name = Debug;
		}};
		{ids['app_release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ARCHS = "arm64 x86_64";
				ONLY_ACTIVE_ARCH = NO;
				CODE_SIGN_ENTITLEMENTS = Sources/Renvert/Renvert.entitlements;
				CODE_SIGN_IDENTITY = "-";
				COMBINE_HIDPI_IMAGES = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Sources/Renvert/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
				PRODUCT_NAME = Renvert;
				SWIFT_EMIT_LOC_STRINGS = YES;
			}};
			name = Release;
		}};
		{ids['test_debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_IDENTITY = "-";
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.renvert.macos.tests;
				PRODUCT_NAME = RenvertTests;
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{ids['test_release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_IDENTITY = "-";
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.renvert.macos.tests;
				PRODUCT_NAME = RenvertTests;
				SWIFT_VERSION = 5.0;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ids['proj_config_list']} /* Build configuration list for PBXProject "Renvert" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['proj_debug']} /* Debug */,
				{ids['proj_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids['app_config_list']} /* Build configuration list for PBXNativeTarget "Renvert" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['app_debug']} /* Debug */,
				{ids['app_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids['test_config_list']} /* Build configuration list for PBXNativeTarget "RenvertTests" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['test_debug']} /* Debug */,
				{ids['test_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {ids['project']} /* Project object */;
}}
"""

scheme_dir = PROJ / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['app_target']}" BuildableName="Renvert.app" BlueprintName="Renvert" ReferencedContainer="container:Renvert.xcodeproj"></BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['test_target']}" BuildableName="RenvertTests.xctest" BlueprintName="RenvertTests" ReferencedContainer="container:Renvert.xcodeproj"></BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['app_target']}" BuildableName="Renvert.app" BlueprintName="Renvert" ReferencedContainer="container:Renvert.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['app_target']}" BuildableName="Renvert.app" BlueprintName="Renvert" ReferencedContainer="container:Renvert.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
"""
(scheme_dir / "Renvert.xcscheme").write_text(scheme)
PROJ.mkdir(exist_ok=True)
(PROJ / "project.pbxproj").write_text(pbx)
print(f"Wrote {PROJ / 'project.pbxproj'}")
