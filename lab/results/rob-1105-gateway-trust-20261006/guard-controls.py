import hashlib,json,pathlib,re,subprocess
repo=pathlib.Path.cwd()
root=repo/"lab/results/rob-1105-gateway-trust-20261006"
test=repo/"test/elara/gateway_trust_test.exs"
cases=[
 ("ignore-auth", "lib/elara/server.ex", ":ok <- authenticate(request, token)", "_ <- authenticate(request, token)", "authentication precedes"),
 ("equal-length-auth", "lib/elara/server.ex", ":crypto.hash_equals(provided, token)", "true", "authentication precedes"),
 ("ignore-trust", "lib/elara/plugin/loader.ex", ":ok <- Elara.Plugin.Trust.check(path, source)", "_ <- Elara.Plugin.Trust.check(path, source)", "unapproved and changed"),
 ("implicit-consent", "lib/mix/tasks/elara.trust.ex", 'is_binary(answer) and String.downcase(String.trim(answer)) in ["y", "yes"]', "is_binary(answer)", "explicit workspace trust"),
]
results=[]
for name,relative,old,new,label in cases:
 path=repo/relative; before=path.read_bytes(); text=before.decode()
 assert text.count(old)==1,(relative,old)
 line=next(i for i,x in enumerate(test.read_text().splitlines(),1) if 'test "'+label in x)
 try:
  path.write_text(text.replace(old,new,1))
  with (root/(name+".log")).open("w") as output:
   result=subprocess.run(["mix","test",str(test)+":"+str(line),"--seed","1105"],stdout=output,stderr=subprocess.STDOUT,timeout=60)
  log=(root/(name+".log")).read_text()
  assert result.returncode==2 and "Result: 0/1 passed" in log,(name,result.returncode)
 finally:
  path.write_bytes(before)
 assert path.read_bytes()==before
 results.append({"name":name,"exit":result.returncode,"result":"0/1 passed","restored_sha256":hashlib.sha256(before).hexdigest()})
 print(name+": expected runtime failure, bytes restored",flush=True)
path=repo/"native/elara-tui/src/lib.rs"; before=path.read_bytes(); text=before.decode()
a=text.index('        if let Ok(token) = std::env::var("ELARA_SERVER_TOKEN") {',text.index('pub fn connect'))
b=text.index('        let stream = TcpStream::connect',a)
mutated=(text[:a]+text[b:]).replace('pub fn connect(port: u16, mut request: Value)','pub fn connect(port: u16, request: Value)',1)
line=next(i for i,x in enumerate(test.read_text().splitlines(),1) if 'test "actual native client' in x)
try:
 path.write_text(mutated)
 with (root/"native-missing-header.log").open("w") as output:
  result=subprocess.run(["mix","test",str(test)+":"+str(line),"--seed","1105"],stdout=output,stderr=subprocess.STDOUT,timeout=90)
 log=(root/"native-missing-header.log").read_text()
 assert result.returncode==2 and "Result: 0/1 passed" in log and "authentication_failed" in log
finally:
 path.write_bytes(before)
assert path.read_bytes()==before
results.append({"name":"native-missing-header","exit":result.returncode,"result":"0/1 passed","restored_sha256":hashlib.sha256(before).hexdigest()})
(root/"guard-control-readback.json").write_text(json.dumps(results,indent=2)+"\n")
print("native missing header: expected failure, bytes restored",flush=True)
