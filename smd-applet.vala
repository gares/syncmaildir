using Gtk;
using Notify;
using GConf;

class smdApplet {

	Gtk.Menu menu = null;
	Gtk.StatusIcon si = null;
	Gtk.Window win = null;
	GConf.Client gconf = null;
	weak GLib.Thread thread = null;

	static const string key_icon = "/apps/smd-applet/icon_only_on_errors";
	static const string key_newmail = "/apps/smd-applet/notify_new_mail";

	smdApplet(Gtk.Builder builder) {
		gconf = GConf.Client.get_default();

		win = builder.get_object("wPrefs") as Window;
		var close = builder.get_object("bClose") as Button;
		close.clicked += (b) =>  { win.hide(); };
		var bicon = builder.get_object("cbIcon") as CheckButton;
		bicon.set_active( gconf.get_bool(key_icon));
		bicon.toggled += (b) => {
			try { gconf.set_bool(key_icon,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};
		var bnotify = builder.get_object("cbNotify") as CheckButton;
		bnotify.set_active( gconf.get_bool(key_newmail));
		bnotify.toggled += (b) => {
			try { gconf.set_bool(key_newmail,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};

        menu = builder.get_object ("mMain") as Menu;
		var quit = builder.get_object ("miQuit") as MenuItem;
		quit.activate += (b) => { Gtk.main_quit(); };
		var about = builder.get_object ("miAbout") as MenuItem;
		about.activate += (b) => { si.set_blinking(true); };
		var prefs = builder.get_object ("miPrefs") as MenuItem;
		prefs.activate += (b) => {  win.show(); };

		si = new StatusIcon.from_stock(Gtk.STOCK_NETWORK);
		si.activate += (s) => { 
			menu.popup(null,null,si.position_menu,0,
				Gtk.get_current_event_time());
		};
		si.set_visible(true);

		// var not = new Notify.Notification("foo","bar","gtk-about",null);
		// not.attach_to_status_icon(si);
		// not.show();
	}

	public void *smdThread() {
		int[] p = new int[2]; 
		if (Posix.pipe(p) != 0) {
			stderr.printf("pipe() failed\n");
			return null;
		}
		Posix.pid_t pid;
		if ( (pid = Posix.fork()) == 0 ){
			// son
			string cmd = "/usr/bin/cal";
			Posix.dup2(p[1],1);
			Posix.execl(cmd,cmd);
			stderr.printf("Unable to exec "+cmd+"\n");
			Posix.exit(1);
		} else if (pid > 0) {
			int size = 10;
			char[] buff = new char[size];
			Posix.timeval t = Posix.timeval();
			t.tv_sec = 1;
			t.tv_usec = 0;
			Posix.fd_set fds = Posix.fd_set();
			while(true){
				Posix.FD_ZERO(fds);
				Posix.FD_SET(p[0],fds);
				int n = Posix.select(p[0]+1,fds,null,null,t);
				if (n == 0) {
					int rc;
					int pi = Posix.waitpid(pid,out rc,1); // Posix.WNOHANG
					if (pi == pid) break;
				}
				if (n > 0) {
					ssize_t nread = Posix.read(p[0], buff, size);
					Posix.write(0,buff,nread);
				} else {
					break;
				}
			}
		} else {
			stderr.printf("fork() failed\n");
		}
		return null;
	}

	void run() { 
		try { thread = GLib.Thread.create(smdThread,true); }
		catch (GLib.ThreadError e) { stderr.printf("unable to start\n"); }
		Gtk.main(); 
		thread.join();
	}

	static int main(string[] args){
		Gtk.init (ref args);
		Notify.init("smd-applet");
	
		var builder = new Builder ();
		try { builder.add_from_file ("smd-applet.ui"); } 
		catch (GLib.Error e) { stderr.printf("%s\n",e.message); return 1; }
	
		var smd_applet = new smdApplet(builder);
	
		smd_applet.run();
		
		return 0;
	}

}

// vim:set ts=4:
