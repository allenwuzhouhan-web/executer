#!/usr/bin/env python3
"""Generate Executer.xcodeproj/project.pbxproj"""

import os
import hashlib

def gen_id(name):
    """Generate a 24-char hex ID from a name."""
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()

# All source files relative to project root
swift_files = [
    # App
    ("App/ExecuterApp.swift", "App"),
    ("App/AppDelegate.swift", "App"),
    ("App/AppState.swift", "App"),
    ("App/AttachedFile.swift", "App"),
    ("App/ContextualAwareness.swift", "App"),
    ("App/HealthCheckService.swift", "App"),
    ("App/HotkeyManager.swift", "App"),
    ("App/InputBarState.swift", "App"),
    ("App/SystemContext.swift", "App"),
    ("App/NewsBriefingService.swift", "App"),
    # Automation
    ("Automation/AutomationExecutor.swift", "Automation"),
    ("Automation/AutomationRule.swift", "Automation"),
    ("Automation/AutomationRuleManager.swift", "Automation"),
    ("Automation/RuleParser.swift", "Automation"),
    ("Automation/SystemEventBus.swift", "Automation"),
    # Executors
    ("Executors/AppExecutor.swift", "Executors"),
    ("Executors/ClipboardExecutor.swift", "Executors"),
    ("Executors/ClipboardHistoryExecutor.swift", "Executors"),
    ("Executors/CursorExecutor.swift", "Executors"),
    ("Executors/DictionaryExecutor.swift", "Executors"),
    ("Executors/FileContentExecutor.swift", "Executors"),
    ("Executors/FileExecutor.swift", "Executors"),
    ("Executors/FileSearchExecutor.swift", "Executors"),
    ("Executors/KeyboardExecutor.swift", "Executors"),
    ("Executors/MusicExecutor.swift", "Executors"),
    ("Executors/NotificationExecutor.swift", "Executors"),
    ("Executors/PowerExecutor.swift", "Executors"),
    ("Executors/ProductivityExecutor.swift", "Executors"),
    ("Executors/SchedulerExecutor.swift", "Executors"),
    ("Executors/ScreenshotExecutor.swift", "Executors"),
    ("Executors/SystemInfoExecutor.swift", "Executors"),
    ("Executors/SystemSettingsExecutor.swift", "Executors"),
    ("Executors/TerminalExecutor.swift", "Executors"),
    ("Executors/WeatherExecutor.swift", "Executors"),
    ("Executors/WebContentExecutor.swift", "Executors"),
    ("Executors/WebExecutor.swift", "Executors"),
    ("Executors/WindowExecutor.swift", "Executors"),
    ("Executors/NewsExecutor.swift", "Executors"),
    ("Executors/SemanticScholarExecutor.swift", "Executors"),
    # FocusPersonality
    ("FocusPersonality/FocusStateService.swift", "FocusPersonality"),
    ("FocusPersonality/HumorMode.swift", "FocusPersonality"),
    ("FocusPersonality/PersonalityEngine.swift", "FocusPersonality"),
    # Handoff
    ("Handoff/HandoffBadge.swift", "Handoff"),
    ("Handoff/HandoffService.swift", "Handoff"),
    # LLM
    ("LLM/AgentLoop.swift", "LLM"),
    ("LLM/AnthropicService.swift", "LLM"),
    ("LLM/APIKeyManager.swift", "LLM"),
    ("LLM/DeepSeekService.swift", "LLM"),
    ("LLM/LLMProvider.swift", "LLM"),
    ("LLM/LocalCommandRouter.swift", "LLM"),
    ("LLM/SubAgentCoordinator.swift", "LLM"),
    ("LLM/ToolDefinition.swift", "LLM"),
    ("LLM/ToolRegistry.swift", "LLM"),
    # LLM/CommandMatchers
    ("LLM/CommandMatchers/AppCommandMatcher.swift", "LLM/CommandMatchers"),
    ("LLM/CommandMatchers/CommandParsingHelpers.swift", "LLM/CommandMatchers"),
    ("LLM/CommandMatchers/CursorCommandMatcher.swift", "LLM/CommandMatchers"),
    ("LLM/CommandMatchers/DictionaryCommandMatcher.swift", "LLM/CommandMatchers"),
    ("LLM/CommandMatchers/KeyboardCommandMatcher.swift", "LLM/CommandMatchers"),
    ("LLM/CommandMatchers/MusicCommandMatcher.swift", "LLM/CommandMatchers"),
    ("LLM/CommandMatchers/TimerCommandMatcher.swift", "LLM/CommandMatchers"),
    ("LLM/CommandMatchers/WebCommandMatcher.swift", "LLM/CommandMatchers"),
    # Memory
    ("Memory/MemoryManager.swift", "Memory"),
    ("Memory/MemoryExecutor.swift", "Memory"),
    # Notch
    ("Notch/NotchDetector.swift", "Notch"),
    ("Notch/NotchWindow.swift", "Notch"),
    ("Notch/ScreenGeometry.swift", "Notch"),
    # Permissions
    ("Permissions/PermissionManager.swift", "Permissions"),
    ("Permissions/PermissionSetupView.swift", "Permissions"),
    # Skills
    ("Skills/SkillExecutor.swift", "Skills"),
    ("Skills/SkillsManager.swift", "Skills"),
    # Storage
    ("Storage/AliasManager.swift", "Storage"),
    ("Storage/ClipboardHistory.swift", "Storage"),
    ("Storage/CommandHistory.swift", "Storage"),
    ("Storage/FileIndex.swift", "Storage"),
    ("Storage/KeychainHelper.swift", "Storage"),
    ("Storage/TaskScheduler.swift", "Storage"),
    # ThoughtContinuity
    ("ThoughtContinuity/TextSnapshotService.swift", "ThoughtContinuity"),
    ("ThoughtContinuity/ThoughtDatabase.swift", "ThoughtContinuity"),
    ("ThoughtContinuity/ThoughtRecallCard.swift", "ThoughtContinuity"),
    ("ThoughtContinuity/ThoughtRecallService.swift", "ThoughtContinuity"),
    # UI/Animations
    ("UI/Animations/LaunchGlowView.swift", "UI/Animations"),
    ("UI/Animations/LaunchGlowWindow.swift", "UI/Animations"),
    ("UI/Animations/ResponseGlowView.swift", "UI/Animations"),
    ("UI/Animations/ShimmerView.swift", "UI/Animations"),
    ("UI/Animations/StartupSound.swift", "UI/Animations"),
    # UI/InputBar
    ("UI/InputBar/InputBarHelpers.swift", "UI/InputBar"),
    ("UI/InputBar/InputBarPanel.swift", "UI/InputBar"),
    ("UI/InputBar/InputBarView.swift", "UI/InputBar"),
    ("UI/InputBar/ResultBubbleView.swift", "UI/InputBar"),
    # UI/Onboarding
    ("UI/Onboarding/SettingsView.swift", "UI/Onboarding"),
    # UI/Settings
    ("UI/Settings/AboutSettingsTab.swift", "UI/Settings"),
    ("UI/Settings/AIModelSettingsTab.swift", "UI/Settings"),
    ("UI/Settings/NotchSettingsTab.swift", "UI/Settings"),
    ("UI/Settings/PermissionsSettingsTab.swift", "UI/Settings"),
    ("UI/Settings/VoiceSettingsTab.swift", "UI/Settings"),
    # UI/Theming
    ("UI/Theming/VisualEffectBackground.swift", "UI/Theming"),
    # Utilities
    ("Utilities/AppleScriptRunner.swift", "Utilities"),
    ("Utilities/PathSecurity.swift", "Utilities"),
    # Voice
    ("Voice/AssistantNameManager.swift", "Voice"),
    ("Voice/VoiceCalibration.swift", "Voice"),
    ("Voice/VoiceGlowWindow.swift", "Voice"),
    ("Voice/VoiceIntegration.swift", "Voice"),
    ("Voice/VoiceService.swift", "Voice"),
    ("Voice/VoiceState.swift", "Voice"),
    # Security
    ("Security/AuditLog.swift", "Security"),
    ("Security/InputSanitizer.swift", "Security"),
    ("Security/SecureStorage.swift", "Security"),
    ("Security/SecurityGateway.swift", "Security"),
    ("Security/ShellSanitizer.swift", "Security"),
    ("Security/ToolSafetyClassifier.swift", "Security"),
    # WeChat
    ("WeChat/MessageParser.swift", "WeChat"),
    ("WeChat/MessageRouter.swift", "WeChat"),
    ("WeChat/WeChatAccessibility.swift", "WeChat"),
    ("WeChat/WeChatConfirmCard.swift", "WeChat"),
    ("WeChat/WeChatExecutor.swift", "WeChat"),
    ("WeChat/WeChatMCPClient.swift", "WeChat"),
    ("WeChat/WeChatSentLog.swift", "WeChat"),
    ("WeChat/WeChatService.swift", "WeChat"),
]

# Generate IDs
file_refs = {}  # path -> file_ref_id
build_files = {}  # path -> build_file_id
for path, group in swift_files:
    file_refs[path] = gen_id(f"fileref_{path}")
    build_files[path] = gen_id(f"buildfile_{path}")

# Special files
INFO_PLIST_REF = gen_id("fileref_Info.plist")
ENTITLEMENTS_REF = gen_id("fileref_Executer.entitlements")
ASSETS_REF = gen_id("fileref_Assets.xcassets")
ASSETS_BUILD = gen_id("buildfile_Assets.xcassets")
PRODUCT_REF = gen_id("fileref_Executer.app")

# Groups
groups = {
    "main": gen_id("group_Executer"),
    "App": gen_id("group_App"),
    "Automation": gen_id("group_Automation"),
    "Notch": gen_id("group_Notch"),
    "UI": gen_id("group_UI"),
    "UI/InputBar": gen_id("group_UI_InputBar"),
    "UI/Animations": gen_id("group_UI_Animations"),
    "UI/Theming": gen_id("group_UI_Theming"),
    "UI/Onboarding": gen_id("group_UI_Onboarding"),
    "UI/Settings": gen_id("group_UI_Settings"),
    "LLM": gen_id("group_LLM"),
    "LLM/CommandMatchers": gen_id("group_LLM_CommandMatchers"),
    "Executors": gen_id("group_Executors"),
    "Skills": gen_id("group_Skills"),
    "Memory": gen_id("group_Memory"),
    "Permissions": gen_id("group_Permissions"),
    "Storage": gen_id("group_Storage"),
    "Utilities": gen_id("group_Utilities"),
    "Resources": gen_id("group_Resources"),
    "ThoughtContinuity": gen_id("group_ThoughtContinuity"),
    "FocusPersonality": gen_id("group_FocusPersonality"),
    "Handoff": gen_id("group_Handoff"),
    "Voice": gen_id("group_Voice"),
    "Security": gen_id("group_Security"),
    "WeChat": gen_id("group_WeChat"),
    "Products": gen_id("group_Products"),
    "Frameworks": gen_id("group_Frameworks"),
    "root": gen_id("group_root"),
}

# Other IDs
PROJECT_ID = gen_id("project_Executer")
TARGET_ID = gen_id("target_Executer")
SOURCES_PHASE = gen_id("sources_phase")
FRAMEWORKS_PHASE = gen_id("frameworks_phase")
RESOURCES_PHASE = gen_id("resources_phase")
PROJECT_DEBUG = gen_id("config_project_debug")
PROJECT_RELEASE = gen_id("config_project_release")
TARGET_DEBUG = gen_id("config_target_debug")
TARGET_RELEASE = gen_id("config_target_release")
PROJECT_CONFIG_LIST = gen_id("configlist_project")
TARGET_CONFIG_LIST = gen_id("configlist_target")

# Framework references and build files
frameworks = [
    ("EventKit.framework", "System/Library/Frameworks"),
    ("UserNotifications.framework", "System/Library/Frameworks"),
    ("ApplicationServices.framework", "System/Library/Frameworks"),
    ("Security.framework", "System/Library/Frameworks"),
    ("IOBluetooth.framework", "System/Library/Frameworks"),
    ("AVFoundation.framework", "System/Library/Frameworks"),
    ("Vision.framework", "System/Library/Frameworks"),
]
fw_refs = {}
fw_builds = {}
for fw_name, _ in frameworks:
    fw_refs[fw_name] = gen_id(f"fwref_{fw_name}")
    fw_builds[fw_name] = gen_id(f"fwbuild_{fw_name}")

# Build pbxproj
lines = []
lines.append('// !$*UTF8*$!')
lines.append('{')
lines.append('\tarchiveVersion = 1;')
lines.append('\tclasses = {')
lines.append('\t};')
lines.append('\tobjectVersion = 56;')
lines.append('\tobjects = {')

# PBXBuildFile
lines.append('')
lines.append('/* Begin PBXBuildFile section */')
for path, group in swift_files:
    name = os.path.basename(path)
    lines.append(f'\t\t{build_files[path]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {name} */; }};')
lines.append(f'\t\t{ASSETS_BUILD} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS_REF} /* Assets.xcassets */; }};')
for fw_name, _ in frameworks:
    lines.append(f'\t\t{fw_builds[fw_name]} /* {fw_name} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {fw_refs[fw_name]} /* {fw_name} */; }};')
lines.append('/* End PBXBuildFile section */')

# PBXFileReference
lines.append('')
lines.append('/* Begin PBXFileReference section */')
for path, group in swift_files:
    name = os.path.basename(path)
    lines.append(f'\t\t{file_refs[path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
lines.append(f'\t\t{INFO_PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
lines.append(f'\t\t{ENTITLEMENTS_REF} /* Executer.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Executer.entitlements; sourceTree = "<group>"; }};')
lines.append(f'\t\t{ASSETS_REF} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
lines.append(f'\t\t{PRODUCT_REF} /* Executer.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Executer.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
for fw_name, fw_path in frameworks:
    lines.append(f'\t\t{fw_refs[fw_name]} /* {fw_name} */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {fw_name}; path = {fw_path}/{fw_name}; sourceTree = SDKROOT; }};')
lines.append('/* End PBXFileReference section */')

# PBXFrameworksBuildPhase
lines.append('')
lines.append('/* Begin PBXFrameworksBuildPhase section */')
lines.append(f'\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{')
lines.append('\t\t\tisa = PBXFrameworksBuildPhase;')
lines.append('\t\t\tbuildActionMask = 2147483647;')
lines.append('\t\t\tfiles = (')
for fw_name, _ in frameworks:
    lines.append(f'\t\t\t\t{fw_builds[fw_name]} /* {fw_name} in Frameworks */,')
lines.append('\t\t\t);')
lines.append('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
lines.append('\t\t};')
lines.append('/* End PBXFrameworksBuildPhase section */')

# PBXGroup
lines.append('')
lines.append('/* Begin PBXGroup section */')

# Root group
lines.append(f'\t\t{groups["root"]} = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
lines.append(f'\t\t\t\t{groups["main"]} /* Executer */,')
lines.append(f'\t\t\t\t{groups["Products"]} /* Products */,')
lines.append(f'\t\t\t\t{groups["Frameworks"]} /* Frameworks */,')
lines.append('\t\t\t);')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

# Products group
lines.append(f'\t\t{groups["Products"]} /* Products */ = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
lines.append(f'\t\t\t\t{PRODUCT_REF} /* Executer.app */,')
lines.append('\t\t\t);')
lines.append('\t\t\tname = Products;')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

# Frameworks group
lines.append(f'\t\t{groups["Frameworks"]} /* Frameworks */ = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
for fw_name, _ in frameworks:
    lines.append(f'\t\t\t\t{fw_refs[fw_name]} /* {fw_name} */,')
lines.append('\t\t\t);')
lines.append('\t\t\tname = Frameworks;')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

# Main Executer group
main_children = [
    (groups["App"], "App"),
    (groups["Automation"], "Automation"),
    (groups["Notch"], "Notch"),
    (groups["UI"], "UI"),
    (groups["LLM"], "LLM"),
    (groups["Executors"], "Executors"),
    (groups["Skills"], "Skills"),
    (groups["Memory"], "Memory"),
    (groups["Permissions"], "Permissions"),
    (groups["Storage"], "Storage"),
    (groups["Utilities"], "Utilities"),
    (groups["ThoughtContinuity"], "ThoughtContinuity"),
    (groups["FocusPersonality"], "FocusPersonality"),
    (groups["Handoff"], "Handoff"),
    (groups["Voice"], "Voice"),
    (groups["Security"], "Security"),
    (groups["WeChat"], "WeChat"),
    (groups["Resources"], "Resources"),
    (INFO_PLIST_REF, "Info.plist"),
    (ENTITLEMENTS_REF, "Executer.entitlements"),
]
lines.append(f'\t\t{groups["main"]} /* Executer */ = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
for child_id, child_name in main_children:
    lines.append(f'\t\t\t\t{child_id} /* {child_name} */,')
lines.append('\t\t\t);')
lines.append('\t\t\tpath = Executer;')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

# File groups
group_files = {}
for path, group in swift_files:
    if group not in group_files:
        group_files[group] = []
    group_files[group].append((file_refs[path], os.path.basename(path)))

simple_groups = ["App", "Automation", "Notch", "Executors", "Skills", "Memory", "Permissions", "Storage", "Utilities", "ThoughtContinuity", "FocusPersonality", "Handoff", "Voice", "Security", "WeChat"]
for g in simple_groups:
    lines.append(f'\t\t{groups[g]} /* {g} */ = {{')
    lines.append('\t\t\tisa = PBXGroup;')
    lines.append('\t\t\tchildren = (')
    for fid, fname in group_files.get(g, []):
        lines.append(f'\t\t\t\t{fid} /* {fname} */,')
    lines.append('\t\t\t);')
    lines.append(f'\t\t\tpath = {g};')
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append('\t\t};')

# UI group (has subgroups)
lines.append(f'\t\t{groups["UI"]} /* UI */ = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
lines.append(f'\t\t\t\t{groups["UI/InputBar"]} /* InputBar */,')
lines.append(f'\t\t\t\t{groups["UI/Animations"]} /* Animations */,')
lines.append(f'\t\t\t\t{groups["UI/Theming"]} /* Theming */,')
lines.append(f'\t\t\t\t{groups["UI/Onboarding"]} /* Onboarding */,')
lines.append(f'\t\t\t\t{groups["UI/Settings"]} /* Settings */,')
lines.append('\t\t\t);')
lines.append('\t\t\tpath = UI;')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

for subg in ["UI/InputBar", "UI/Animations", "UI/Theming", "UI/Onboarding", "UI/Settings"]:
    short_name = subg.split("/")[-1]
    lines.append(f'\t\t{groups[subg]} /* {short_name} */ = {{')
    lines.append('\t\t\tisa = PBXGroup;')
    lines.append('\t\t\tchildren = (')
    for fid, fname in group_files.get(subg, []):
        lines.append(f'\t\t\t\t{fid} /* {fname} */,')
    lines.append('\t\t\t);')
    lines.append(f'\t\t\tpath = {short_name};')
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append('\t\t};')

# LLM group (has CommandMatchers subgroup)
lines.append(f'\t\t{groups["LLM"]} /* LLM */ = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
for fid, fname in group_files.get("LLM", []):
    lines.append(f'\t\t\t\t{fid} /* {fname} */,')
lines.append(f'\t\t\t\t{groups["LLM/CommandMatchers"]} /* CommandMatchers */,')
lines.append('\t\t\t);')
lines.append('\t\t\tpath = LLM;')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

# LLM/CommandMatchers subgroup
lines.append(f'\t\t{groups["LLM/CommandMatchers"]} /* CommandMatchers */ = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
for fid, fname in group_files.get("LLM/CommandMatchers", []):
    lines.append(f'\t\t\t\t{fid} /* {fname} */,')
lines.append('\t\t\t);')
lines.append('\t\t\tpath = CommandMatchers;')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

# Resources group
lines.append(f'\t\t{groups["Resources"]} /* Resources */ = {{')
lines.append('\t\t\tisa = PBXGroup;')
lines.append('\t\t\tchildren = (')
lines.append(f'\t\t\t\t{ASSETS_REF} /* Assets.xcassets */,')
lines.append('\t\t\t);')
lines.append('\t\t\tpath = Resources;')
lines.append('\t\t\tsourceTree = "<group>";')
lines.append('\t\t};')

lines.append('/* End PBXGroup section */')

# PBXNativeTarget
lines.append('')
lines.append('/* Begin PBXNativeTarget section */')
lines.append(f'\t\t{TARGET_ID} /* Executer */ = {{')
lines.append('\t\t\tisa = PBXNativeTarget;')
lines.append(f'\t\t\tbuildConfigurationList = {TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Executer" */;')
lines.append('\t\t\tbuildPhases = (')
lines.append(f'\t\t\t\t{SOURCES_PHASE} /* Sources */,')
lines.append(f'\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,')
lines.append(f'\t\t\t\t{RESOURCES_PHASE} /* Resources */,')
lines.append('\t\t\t);')
lines.append('\t\t\tbuildRules = (')
lines.append('\t\t\t);')
lines.append('\t\t\tdependencies = (')
lines.append('\t\t\t);')
lines.append('\t\t\tname = Executer;')
lines.append('\t\t\tproductName = Executer;')
lines.append(f'\t\t\tproductReference = {PRODUCT_REF} /* Executer.app */;')
lines.append('\t\t\tproductType = "com.apple.product-type.application";')
lines.append('\t\t};')
lines.append('/* End PBXNativeTarget section */')

# PBXProject
lines.append('')
lines.append('/* Begin PBXProject section */')
lines.append(f'\t\t{PROJECT_ID} /* Project object */ = {{')
lines.append('\t\t\tisa = PBXProject;')
lines.append(f'\t\t\tbuildConfigurationList = {PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "Executer" */;')
lines.append('\t\t\tcompatibilityVersion = "Xcode 14.0";')
lines.append('\t\t\tdevelopmentRegion = en;')
lines.append('\t\t\thasScannedForEncodings = 0;')
lines.append('\t\t\tknownRegions = (')
lines.append('\t\t\t\ten,')
lines.append('\t\t\t\tBase,')
lines.append('\t\t\t);')
lines.append(f'\t\t\tmainGroup = {groups["root"]};')
lines.append(f'\t\t\tproductRefGroup = {groups["Products"]} /* Products */;')
lines.append('\t\t\tprojectDirPath = "";')
lines.append('\t\t\tprojectRoot = "";')
lines.append('\t\t\ttargets = (')
lines.append(f'\t\t\t\t{TARGET_ID} /* Executer */,')
lines.append('\t\t\t);')
lines.append('\t\t};')
lines.append('/* End PBXProject section */')

# PBXResourcesBuildPhase
lines.append('')
lines.append('/* Begin PBXResourcesBuildPhase section */')
lines.append(f'\t\t{RESOURCES_PHASE} /* Resources */ = {{')
lines.append('\t\t\tisa = PBXResourcesBuildPhase;')
lines.append('\t\t\tbuildActionMask = 2147483647;')
lines.append('\t\t\tfiles = (')
lines.append(f'\t\t\t\t{ASSETS_BUILD} /* Assets.xcassets in Resources */,')
lines.append('\t\t\t);')
lines.append('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
lines.append('\t\t};')
lines.append('/* End PBXResourcesBuildPhase section */')

# PBXSourcesBuildPhase
lines.append('')
lines.append('/* Begin PBXSourcesBuildPhase section */')
lines.append(f'\t\t{SOURCES_PHASE} /* Sources */ = {{')
lines.append('\t\t\tisa = PBXSourcesBuildPhase;')
lines.append('\t\t\tbuildActionMask = 2147483647;')
lines.append('\t\t\tfiles = (')
for path, group in swift_files:
    name = os.path.basename(path)
    lines.append(f'\t\t\t\t{build_files[path]} /* {name} in Sources */,')
lines.append('\t\t\t);')
lines.append('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
lines.append('\t\t};')
lines.append('/* End PBXSourcesBuildPhase section */')

# XCBuildConfiguration
lines.append('')
lines.append('/* Begin XCBuildConfiguration section */')

# Project Debug
lines.append(f'\t\t{PROJECT_DEBUG} /* Debug */ = {{')
lines.append('\t\t\tisa = XCBuildConfiguration;')
lines.append('\t\t\tbuildSettings = {')
lines.append('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
lines.append('\t\t\t\tCLANG_ANALYZER_NONNULL = YES;')
lines.append('\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";')
lines.append('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
lines.append('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
lines.append('\t\t\t\tCOPY_PHASE_STRIP = NO;')
lines.append('\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;')
lines.append('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
lines.append('\t\t\t\tENABLE_TESTABILITY = YES;')
lines.append('\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;')
lines.append('\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;')
lines.append('\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (')
lines.append('\t\t\t\t\t"DEBUG=1",')
lines.append('\t\t\t\t\t"$(inherited)",')
lines.append('\t\t\t\t);')
lines.append('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
lines.append('\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;')
lines.append('\t\t\t\tONLY_ACTIVE_ARCH = YES;')
lines.append('\t\t\t\tSDKROOT = macosx;')
lines.append('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;')
lines.append('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
lines.append('\t\t\t};')
lines.append('\t\t\tname = Debug;')
lines.append('\t\t};')

# Project Release
lines.append(f'\t\t{PROJECT_RELEASE} /* Release */ = {{')
lines.append('\t\t\tisa = XCBuildConfiguration;')
lines.append('\t\t\tbuildSettings = {')
lines.append('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
lines.append('\t\t\t\tCLANG_ANALYZER_NONNULL = YES;')
lines.append('\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";')
lines.append('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
lines.append('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
lines.append('\t\t\t\tCOPY_PHASE_STRIP = NO;')
lines.append('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
lines.append('\t\t\t\tENABLE_NS_ASSERTIONS = NO;')
lines.append('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
lines.append('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
lines.append('\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;')
lines.append('\t\t\t\tSDKROOT = macosx;')
lines.append('\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;')
lines.append('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";')
lines.append('\t\t\t};')
lines.append('\t\t\tname = Release;')
lines.append('\t\t};')

# Target Debug
lines.append(f'\t\t{TARGET_DEBUG} /* Debug */ = {{')
lines.append('\t\t\tisa = XCBuildConfiguration;')
lines.append('\t\t\tbuildSettings = {')
lines.append('\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
lines.append('\t\t\t\tCODE_SIGN_ENTITLEMENTS = Executer/Executer.entitlements;')
lines.append('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
lines.append('\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;')
lines.append('\t\t\t\tENABLE_APP_SANDBOX = NO;')
lines.append('\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
lines.append('\t\t\t\tINFOPLIST_FILE = Executer/Info.plist;')
lines.append('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
lines.append('\t\t\t\t\t"$(inherited)",')
lines.append('\t\t\t\t\t"@executable_path/../Frameworks",')
lines.append('\t\t\t\t);')
lines.append('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.allenwu.executer;')
lines.append('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
lines.append('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
lines.append('\t\t\t\tSWIFT_VERSION = 5.0;')
lines.append('\t\t\t};')
lines.append('\t\t\tname = Debug;')
lines.append('\t\t};')

# Target Release
lines.append(f'\t\t{TARGET_RELEASE} /* Release */ = {{')
lines.append('\t\t\tisa = XCBuildConfiguration;')
lines.append('\t\t\tbuildSettings = {')
lines.append('\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
lines.append('\t\t\t\tCODE_SIGN_ENTITLEMENTS = Executer/Executer.entitlements;')
lines.append('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
lines.append('\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;')
lines.append('\t\t\t\tENABLE_APP_SANDBOX = NO;')
lines.append('\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
lines.append('\t\t\t\tINFOPLIST_FILE = Executer/Info.plist;')
lines.append('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
lines.append('\t\t\t\t\t"$(inherited)",')
lines.append('\t\t\t\t\t"@executable_path/../Frameworks",')
lines.append('\t\t\t\t);')
lines.append('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.allenwu.executer;')
lines.append('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
lines.append('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
lines.append('\t\t\t\tSWIFT_VERSION = 5.0;')
lines.append('\t\t\t};')
lines.append('\t\t\tname = Release;')
lines.append('\t\t};')

lines.append('/* End XCBuildConfiguration section */')

# XCConfigurationList
lines.append('')
lines.append('/* Begin XCConfigurationList section */')
lines.append(f'\t\t{PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "Executer" */ = {{')
lines.append('\t\t\tisa = XCConfigurationList;')
lines.append('\t\t\tbuildConfigurations = (')
lines.append(f'\t\t\t\t{PROJECT_DEBUG} /* Debug */,')
lines.append(f'\t\t\t\t{PROJECT_RELEASE} /* Release */,')
lines.append('\t\t\t);')
lines.append('\t\t\tdefaultConfigurationIsVisible = 0;')
lines.append('\t\t\tdefaultConfigurationName = Release;')
lines.append('\t\t};')
lines.append(f'\t\t{TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Executer" */ = {{')
lines.append('\t\t\tisa = XCConfigurationList;')
lines.append('\t\t\tbuildConfigurations = (')
lines.append(f'\t\t\t\t{TARGET_DEBUG} /* Debug */,')
lines.append(f'\t\t\t\t{TARGET_RELEASE} /* Release */,')
lines.append('\t\t\t);')
lines.append('\t\t\tdefaultConfigurationIsVisible = 0;')
lines.append('\t\t\tdefaultConfigurationName = Release;')
lines.append('\t\t};')
lines.append('/* End XCConfigurationList section */')

lines.append('\t};')
lines.append(f'\trootObject = {PROJECT_ID} /* Project object */;')
lines.append('}')

# Write to file
output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "Executer.xcodeproj", "project.pbxproj")
os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f"Generated {output_path}")
print(f"Total source files: {len(swift_files)}")
print(f"Total frameworks: {len(frameworks)}")
