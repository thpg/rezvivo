from pathlib import Path
import subprocess
import argparse
import tempfile
parser=argparse.ArgumentParser(description='Test Android optional-write rejection without a radio or Android runtime.')
parser.add_argument('--jdk', type=Path, required=True, help='JDK directory containing bin/java and bin/javac')
args=parser.parse_args()
R=Path(__file__).resolve().parents[2]
src=(R/'rezvivo-osm-bckl/platforms/android/service/app/src/main/java/io/castleengine/ServiceRezvivo.java').read_text(encoding='utf-8')
# Execute the actual completed/rejection methods; substitute only Android
# scheduling/connection side effects, not their control-flow decisions.
methods=src[src.index('        void completed(int status) {'):src.index('        void next() {')]
temporary=tempfile.TemporaryDirectory(prefix='rezvivo-ble-queue-')
root=Path(temporary.name)
source='''public class QueueRejectionTest {
  static class BluetoothGatt { static final int GATT_SUCCESS=0; }
  static class Operation { boolean subscribe; String service,characteristic;
    Operation(boolean sub,String svc,String chr) { subscribe=sub;service=svc;characteristic=chr; } }
  static class Main { void removeCallbacks(Runnable r) {} }
  Main main=new Main(); Runnable timeout; Operation pending; String address="test";
  int failed,continued,notices;
  void fail(String reason) { failed++; }
  void next() { continued++; }
  void messageSend(String[] p) { notices++; }
'''+methods+'''
  static final String S="d273f680-d548-419d-b9d1-fa0472345229";
  static final String C="d273f683-d548-419d-b9d1-fa0472345229";
  static int checks;
  static void check(boolean value) { checks++;if(!value)throw new AssertionError("check "+checks); }
  public static void main(String[] args) {
    QueueRejectionTest q=new QueueRejectionTest();
    q.pending=new Operation(false,S,C);q.completed(13);
    check(q.failed==0);check(q.continued==1);check(q.pending==null);check(q.notices==1);
    q.pending=new Operation(false,S.toUpperCase(),C.toUpperCase());q.operationRejected("rejected");
    check(q.failed==0 && q.continued==2);
    q.pending=new Operation(true,S,C);q.completed(13);
    check(q.failed==1 && q.continued==2);
    q.pending=new Operation(false,"00001826-0000-1000-8000-00805f9b34fb","00002ad9-0000-1000-8000-00805f9b34fb");q.completed(13);
    check(q.failed==2 && q.continued==2);
    q.pending=new Operation(false,"different-service",C);q.operationRejected("missing");
    check(q.failed==3);
    q.pending=new Operation(false,S,"different-characteristic");q.operationRejected("rejected");
    check(q.failed==4);
    q.pending=new Operation(false,S,C);q.completed(0);
    check(q.failed==4 && q.continued==3 && q.pending==null && q.notices==2);
    q.completed(13);check(q.failed==4 && q.continued==3);
    System.out.println("PASS Android optional App Information queue: "+checks+" checks");
  }
}'''
(root/'QueueRejectionTest.java').write_text(source,encoding='utf-8')
jdk=args.jdk/'bin'
import os
suffix='.exe' if os.name=='nt' else ''
subprocess.run([str(jdk/('javac'+suffix)),str(root/'QueueRejectionTest.java')],check=True)
p=subprocess.run([str(jdk/('java'+suffix)),'-cp',str(root),'QueueRejectionTest'],capture_output=True,text=True,check=True)
print(p.stdout,end='')
temporary.cleanup()
