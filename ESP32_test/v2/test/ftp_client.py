"""ftp_client.py -- the FTP server test's client side (run with a Windows Python):
starts ftp_test.exe on a scratch folder, drives it with ftplib, compares the folder with what was sent.
python ftp_client.py ftp_test.exe WORKDIR
"""
import ftplib, io, os, random, shutil, socket, subprocess, sys, time

exe, work = sys.argv[1], sys.argv[2]
PORT = 2121
root = os.path.join(work, "root")
shutil.rmtree(root, ignore_errors=True)
os.makedirs(os.path.join(root, "GAMES", "a1"))
rnd = random.Random(1)
seed = {"GAMES/a1/first.tap": rnd.randbytes(70000), "readme.txt": b"hello\r\n", "GAMES/empty.bin": b""}
for name, data in seed.items():
    open(os.path.join(root, name), "wb").write(data)

srv = subprocess.Popen([exe, root.replace("\\", "/"), str(PORT)], stdout=subprocess.PIPE)
fails = 0

def check(what, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + what)
    fails += 0 if ok else 1

def refused(call, *args):
    try:
        call(*args)
    except ftplib.error_perm:
        return True
    return False

def connect(user=None):
    f = ftplib.FTP()
    f.connect("127.0.0.1", PORT, timeout=10)
    if user is None:
        f.login()
    else:
        f.login(user, "whatever")
    return f

def get(f, name, rest=None):
    buf = io.BytesIO()
    f.retrbinary("RETR " + name, buf.write, rest=rest)
    return buf.getvalue()

def on_disk(name):
    return open(os.path.join(root, name), "rb").read()

try:
    check("server started", srv.stdout.readline().strip() == b"ftp_test: running")
    f = connect()
    check("anonymous login, welcome 220", f.getwelcome().startswith("220"))
    g = connect("somebody")
    check("any user name and password", g.pwd() == "/")
    g.quit()
    check("SYST", f.sendcmd("SYST").startswith("215"))
    check("FEAT lists SIZE", "SIZE" in f.sendcmd("FEAT"))
    check("unknown command 502", refused(f.sendcmd, "XYZZ"))

    # listings
    lines = []
    f.retrlines("LIST", lines.append)
    names = {l.split(None, 8)[8]: l for l in lines}
    check("LIST root: GAMES is a folder, readme.txt is a file of 7 bytes",
          set(names) == {"GAMES", "readme.txt"} and names["GAMES"][0] == "d" and names["readme.txt"][0] == "-"
          and names["readme.txt"].split()[4] == "7")
    check("NLST", sorted(f.nlst()) == ["GAMES", "readme.txt"])
    check("LIST -la with a path", len(f.nlst("-la", "/GAMES")) == 2)
    f.cwd("GAMES/a1")
    check("CWD + PWD", f.pwd() == "/GAMES/a1")
    f.cwd("../../../../..")
    check("nothing above the root", f.pwd() == "/" and sorted(f.nlst("/../..")) == ["GAMES", "readme.txt"])
    check("CWD into a file refused", refused(f.cwd, "readme.txt"))
    check("CWD into nothing refused", refused(f.cwd, "nowhere"))

    # downloads
    check("RETR 70000 bytes", get(f, "GAMES/a1/first.tap") == seed["GAMES/a1/first.tap"])
    check("RETR empty file", get(f, "/GAMES/empty.bin") == b"")
    check("RETR from position 12345 (REST)", get(f, "GAMES/a1/first.tap", rest=12345) == seed["GAMES/a1/first.tap"][12345:])
    check("SIZE", f.size("GAMES/a1/first.tap") == 70000)
    check("MDTM gives 14 digits", len(f.sendcmd("MDTM readme.txt").split()[1]) == 14)
    check("RETR of a folder refused", refused(get, f, "GAMES"))
    check("RETR of nothing refused", refused(get, f, "none.bin"))
    check("RETR without a name 501", refused(f.sendcmd, "RETR"))

    # uploads
    big = rnd.randbytes(3 * 1024 * 1024 + 17)
    long_name = "A long name with spaces, (brackets) and dots.v1.2 - disk 1 of 2.tap"
    f.mkd("NEW")
    f.cwd("NEW")
    t0 = time.time()
    f.storbinary("STOR big.bin", io.BytesIO(big))
    check("STOR 3 MB (%.1f MB/s)" % (len(big) / 1048576 / (time.time() - t0)), on_disk("NEW/big.bin") == big)
    check("RETR it back", get(f, "big.bin") == big)
    f.storbinary("STOR " + long_name, io.BytesIO(b"x" * 1000))
    check("STOR long name", on_disk("NEW/" + long_name) == b"x" * 1000 and long_name in f.nlst())
    f.storbinary("STOR " + long_name, io.BytesIO(b"short"))
    check("STOR replaces a file", on_disk("NEW/" + long_name) == b"short")
    f.storbinary("APPE " + long_name, io.BytesIO(b"+more"))
    check("APPE", on_disk("NEW/" + long_name) == b"short+more")
    f.storbinary("STOR " + long_name, io.BytesIO(b"XY"), rest=2)
    check("STOR at a position (REST)", on_disk("NEW/" + long_name) == b"shXYt+more")
    f.storbinary("STOR empty.txt", io.BytesIO(b""))
    check("STOR empty file", on_disk("NEW/empty.txt") == b"")
    check("STOR over a folder refused", refused(f.storbinary, "STOR /GAMES", io.BytesIO(b"x")))
    check("STOR into nothing refused", refused(f.storbinary, "STOR /nowhere/x.bin", io.BytesIO(b"x")))

    # active mode
    f.set_pasv(False)
    check("active mode: NLST", "big.bin" in f.nlst())
    check("active mode: RETR", get(f, "big.bin") == big)
    f.storbinary("STOR active.bin", io.BytesIO(big[:200000]))
    check("active mode: STOR", on_disk("NEW/active.bin") == big[:200000])
    f.set_pasv(True)

    # names
    f.rename("active.bin", "renamed.bin")
    check("RNFR / RNTO", not os.path.exists(os.path.join(root, "NEW/active.bin")) and on_disk("NEW/renamed.bin") == big[:200000])
    f.rename("renamed.bin", "/GAMES/a1/moved.bin")
    check("rename into another folder", on_disk("GAMES/a1/moved.bin") == big[:200000])
    check("RNFR of nothing refused", refused(f.rename, "nothing", "x"))
    check("RNTO without RNFR 503", refused(f.sendcmd, "RNTO x"))
    f.delete("/GAMES/a1/moved.bin")
    check("DELE", not os.path.exists(os.path.join(root, "GAMES/a1/moved.bin")))
    check("DELE of nothing refused", refused(f.delete, "nothing"))
    check("RMD of a folder with files refused", refused(f.rmd, "/NEW"))
    check("RMD / DELE of the root refused", refused(f.rmd, "/") and refused(f.delete, "/"))
    f.mkd("/NEW/sub")
    f.rmd("/NEW/sub")
    check("MKD + RMD", not os.path.exists(os.path.join(root, "NEW/sub")))
    check("MKD of an existing name refused", refused(f.mkd, "/NEW"))

    # several clients: two transfers side by side, a third client browsing, a fourth sent away
    a, b = connect(), connect()
    a.voidcmd("TYPE I"); b.voidcmd("TYPE I")
    ca = a.transfercmd("RETR /NEW/big.bin")
    cb = b.transfercmd("STOR /NEW/second.bin")
    got, sent = b"", 0
    while len(got) < len(big) or sent < len(big):
        if sent < len(big):
            cb.sendall(big[sent:sent + 65536]); sent += 65536
        if len(got) < len(big):
            got += ca.recv(65536)
        if rnd.random() < 0.05:
            f.pwd()
    cb.close(); ca.close()
    check("two transfers side by side: both answered 226", a.voidresp().startswith("226") and b.voidresp().startswith("226"))
    check("two transfers side by side: data", got == big and on_disk("NEW/second.bin") == big)
    try:
        connect()
        check("a fourth client is sent away (421)", False)
    except (ftplib.error_temp, EOFError, OSError) as e:
        check("a fourth client is sent away (421)", "421" in str(e))
    a.quit()
    time.sleep(0.2)
    c = connect()
    check("the place of a client that left is free again", c.pwd() == "/")
    c.quit()

    # a transfer stopped by the client
    b.voidcmd("TYPE I")
    cb = b.transfercmd("RETR /NEW/big.bin")
    cb.recv(1000)
    first = b.abort()                     # ftplib reads one answer; the standard has two (426 transfer, 226 ABOR)
    cb.close()
    check("ABOR during RETR: 426 then 226, the client goes on",
          first.startswith("426") and b.voidresp().startswith("226") and b.pwd() == "/")
    cb = b.transfercmd("STOR /NEW/cut.bin")
    cb.sendall(big[:50000]); cb.close()
    check("upload ended by closing: 226, 50000 bytes kept", b.voidresp().startswith("226") and on_disk("NEW/cut.bin") == big[:50000])
    # a data port asked for and never used, then a client that vanishes during a transfer
    b.sendcmd("PASV")
    check("unused PASV, then another command", b.pwd() == "/")
    cb = b.transfercmd("RETR /NEW/big.bin")
    cb.recv(1000)
    b.close(); cb.close()
    time.sleep(0.5)
    c = connect(); d = connect()
    check("a vanished client's place is free again", c.pwd() == "/" and d.pwd() == "/")
    c.quit(); d.quit()
    check("the first client still works", get(f, "/readme.txt") == b"hello\r\n")
    check("QUIT", f.quit().startswith("221"))
finally:
    srv.kill()
print("FTP server: " + ("PASS" if fails == 0 else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
