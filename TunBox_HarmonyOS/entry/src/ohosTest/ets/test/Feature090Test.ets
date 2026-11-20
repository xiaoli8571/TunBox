import { describe, it, expect } from '@ohos/hypium';
import { ArrayDataSource } from '../../../main/ets/commons/utils/ArrayDataSource';
import { CoreLogLine, CoreLogStream } from '../../../main/ets/commons/services/CoreLogStream';
import {
  AssetMirror, GeoAssetManager, MODEL_MIRRORS, reorderAssetMirrors, ZSTD_MAGIC
} from '../../../main/ets/commons/services/GeoAssetManager';
import { BackupCrypto, ENCRYPTED_APP } from '../../../main/ets/commons/services/BackupCrypto';
import { OrchestratorNetChecks } from '../../../main/ets/commons/services/OrchestratorNetChecks';
import { RuntimeConfigBuilder, RuntimeConfigProfile } from '../../../main/ets/commons/config/RuntimeConfigBuilder';
import { AutoSelectModes } from '../../../main/ets/commons/models/AppSettings';
import { ProxyNode } from '../../../main/ets/commons/models/ProxyNode';

class CountingDataChangeListener implements DataChangeListener {
  reloadCount: number = 0;

  onDataReloaded(): void {
    this.reloadCount++;
  }

  onDataAdded(_index: number): void {}
  onDataAdd(_index: number): void {}
  onDataMoved(_from: number, _to: number): void {}
  onDataMove(_from: number, _to: number): void {}
  onDataDeleted(_index: number): void {}
  onDataDelete(_index: number): void {}
  onDataChanged(_index: number): void {}
  onDataChange(_index: number): void {}
  onDatasetChange(_dataOperations: DataOperation[]): void {}
}

export default function feature090Test() {
  describe('Feature090Test', () => {
    it('array_data_source_lifecycle_and_listener_dedupe', 0, () => {
      const ds = new ArrayDataSource<string>(['a', 'b']);
      expect(ds.totalCount()).assertEqual(2);
      expect(ds.getData(0)).assertEqual('a');
      expect(ds.getData(1)).assertEqual('b');

      const listener = new CountingDataChangeListener();
      ds.registerDataChangeListener(listener);
      ds.registerDataChangeListener(listener);
      ds.replaceAll(['x', 'y', 'z']);
      expect(ds.totalCount()).assertEqual(3);
      expect(ds.getData(2)).assertEqual('z');
      expect(listener.reloadCount).assertEqual(1);

      ds.notifyReload();
      expect(listener.reloadCount).assertEqual(2);

      ds.unregisterDataChangeListener(listener);
      ds.replaceAll(['only']);
      expect(ds.totalCount()).assertEqual(1);
      expect(listener.reloadCount).assertEqual(2);
    });

    it('core_log_stream_listener_count_tracks_attach_and_detach', 0, () => {
      const stream = CoreLogStream.instance();
      const baseCount = stream.listenerCount();
      const fnA = (_lines: CoreLogLine[]): void => {};
      const fnB = (_lines: CoreLogLine[]): void => {};

      stream.addListener(fnA);
      stream.addListener(fnA);
      expect(stream.listenerCount()).assertEqual(baseCount + 1);

      stream.addListener(fnB);
      expect(stream.listenerCount()).assertEqual(baseCount + 2);

      stream.removeListener(fnA);
      stream.removeListener(fnB);
      expect(stream.listenerCount()).assertEqual(baseCount);
      expect(stream.phase()).assertEqual('idle');
    });

    it('geo_asset_magic_validation_and_mirror_reordering', 0, () => {
      const validZstd = new Uint8Array([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x01]).buffer as ArrayBuffer;
      const badZstd = new Uint8Array([0x28, 0xB5, 0x2F, 0x00]).buffer as ArrayBuffer;
      const shortBuf = new Uint8Array([0x28, 0xB5]).buffer as ArrayBuffer;
      expect(GeoAssetManager.bufferMagicOk(validZstd, ZSTD_MAGIC)).assertTrue();
      expect(GeoAssetManager.bufferMagicOk(badZstd, ZSTD_MAGIC)).assertFalse();
      expect(GeoAssetManager.bufferMagicOk(shortBuf, ZSTD_MAGIC)).assertFalse();

      const mmdbMarker: number[] = [
        0xAB, 0xCD, 0xEF, 0x4D, 0x61, 0x78, 0x4D, 0x69, 0x6E, 0x64, 0x2E, 0x63, 0x6F, 0x6D
      ];
      const tailBytes = new Uint8Array(mmdbMarker.length + 4);
      for (let i = 0; i < mmdbMarker.length; i++) {
        tailBytes[i + 2] = mmdbMarker[i];
      }
      expect(GeoAssetManager.bufferTailMagicOk(tailBytes.buffer as ArrayBuffer)).assertTrue();
      expect(GeoAssetManager.bufferTailMagicOk(new Uint8Array([1, 2, 3]).buffer as ArrayBuffer)).assertFalse();

      const reordered = reorderAssetMirrors(MODEL_MIRRORS, 'github');
      expect(reordered.length).assertEqual(MODEL_MIRRORS.length);
      expect(reordered[0].tag).assertEqual('github');
      const autoCopy: AssetMirror[] = reorderAssetMirrors(MODEL_MIRRORS, 'auto');
      expect(autoCopy[0].url).assertEqual(MODEL_MIRRORS[0].url);
    });

    it('backup_crypto_envelope_detection', 0, () => {
      expect(BackupCrypto.isEncrypted(`{"app":"${ENCRYPTED_APP}","version":"1"}`)).assertTrue();
      expect(BackupCrypto.isEncrypted('{"app":"TunBox-Plain","subscriptions":[]}')).assertFalse();
      expect(BackupCrypto.isEncrypted('not-json')).assertFalse();
    });

    it('orchestrator_net_checks_formatters', 0, () => {
      expect(OrchestratorNetChecks.formatSpeed(512)).assertEqual('512 B/s');
      expect(OrchestratorNetChecks.formatSpeed(2048)).assertEqual('2.0 KB/s');
      expect(OrchestratorNetChecks.formatBytes(1024 * 1024 * 2)).assertEqual('2.0 MB');
      expect(OrchestratorNetChecks.connDurationText(0)).assertEqual('');
      expect(OrchestratorNetChecks.notifyNodeText('short')).assertEqual('short');
      expect(OrchestratorNetChecks.notifyNodeText('a'.repeat(30)).length).assertEqual(25);
    });

    it('runtime_config_builder_decide_runtime_options_scoping', 0, () => {
      const profile = new RuntimeConfigProfile();
      const node = new ProxyNode();
      node.name = 'HK-Test';
      profile.nodes = [node];
      profile.selectedNodeName = 'HK-Test';
      profile.profileId = 'sub-1';
      profile.smartModelReady = true;
      profile.geoipReady = true;
      profile.ruleProviderFileReady = true;
      profile.settings.autoSelectMode = AutoSelectModes.AUTO;
      profile.settings.preferredNodeSubscriptionId = 'sub-1';
      profile.settings.hyperAdRulesEnabled = true;

      const enabled = RuntimeConfigBuilder.decideRuntimeOptions(profile);
      expect(enabled.useSmart).assertTrue();
      expect(enabled.ruleProviderReady).assertTrue();
      expect(enabled.useGeoip).assertTrue();
      expect(enabled.selectedNodeName).assertEqual('HK-Test');

      profile.settings.preferredNodeSubscriptionId = 'other-sub';
      const wrongSub = RuntimeConfigBuilder.decideRuntimeOptions(profile);
      expect(wrongSub.useSmart).assertFalse();
    });
  });
}
