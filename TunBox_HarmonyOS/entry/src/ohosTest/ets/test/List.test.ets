import logicTest from './LogicTest';
import { vpnArchTest } from './VpnArchTest';
import feature090Test from './Feature090Test';

export default function testsuite() {
  logicTest();
  vpnArchTest();
  feature090Test();
}
