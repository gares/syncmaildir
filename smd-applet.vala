// Released under the terms of GPLv3 or at your option any later version.
// No warranties.
// Copyright 2009 Enrico Tassi <gares@fettunta.org>


// a simple class to pass data from the child process to the
// notofier
class Event {
	public string message;

	Event(string s) {
		message = s;
	}
}

// the main class containing all the data smd-applet will use
class smdApplet {

	// =================== the constants ===============================

	// gconf keys
	static const string key_icon    = "/apps/smd-applet/icon_only_on_errors";
	static const string key_newmail = "/apps/smd-applet/notify_new_mail";

	// paths, set by main() to something that depends on the 
	// installation path
	public static string smd_loop_cmd = null;
	public static string smd_applet_ui = null;

	// =================== the data =====================================

	// main widgets
	Gtk.Menu menu = null;
	Gtk.StatusIcon si = null;
	Gtk.Window win = null;

	// the gconf client handler
	GConf.Client gconf = null;

	// the thread to manage the child smd-loop instance
	weak GLib.Thread thread = null;
	
	// communication structure between the child process (managed by a thread
	// and the notifier timeout handler).
	GLib.Mutex events_lock = null;
	List<Event> events = null; 

	// =================== the code =====================================

	// initialize data structures and build gtk+ widgets
	smdApplet() {
		// load the ui file
		Gtk.Builder builder = new Gtk.Builder ();
		try { builder.add_from_file (smd_applet_ui); } 
		catch (GLib.Error e) { 
			stderr.printf("%s\n",e.message); 
			Posix.exit(Posix.EXIT_FAILURE);
		}
	
		// events queue and mutex
		events = new List<Event>();
		events_lock = new GLib.Mutex();

		// connect to gconf
		gconf = GConf.Client.get_default();

		// load widgets and attach callbacks
		win = builder.get_object("wPrefs") as Gtk.Window;
		var close = builder.get_object("bClose") as Gtk.Button;
		close.clicked += (b) =>  { win.hide(); };
		var bicon = builder.get_object("cbIcon") as Gtk.CheckButton;
		bicon.set_active( gconf.get_bool(key_icon));
		bicon.toggled += (b) => {
			try { gconf.set_bool(key_icon,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};
		var bnotify = builder.get_object("cbNotify") as Gtk.CheckButton;
		bnotify.set_active( gconf.get_bool(key_newmail));
		bnotify.toggled += (b) => {
			try { gconf.set_bool(key_newmail,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};

		// menu popped up when the user clicks on the notification area
        menu = builder.get_object ("mMain") as Gtk.Menu;
		var quit = builder.get_object ("miQuit") as Gtk.MenuItem;
		quit.activate += (b) => { Gtk.main_quit(); };
		var about = builder.get_object ("miAbout") as Gtk.MenuItem;
		about.activate += (b) => { si.set_blinking(true); };
		var prefs = builder.get_object ("miPrefs") as Gtk.MenuItem;
		prefs.activate += (b) => {  win.show(); };

		// notification area icon (XXX draw a decent one)
		si = new Gtk.StatusIcon.from_stock(Gtk.STOCK_NETWORK);
		si.activate += (s) => { 
			menu.popup(null,null,si.position_menu,0,
				Gtk.get_current_event_time());
		};
		si.set_visible(true);
	}

	// This thread fills the event queue, parsing the
	// stdout of a child process 
	public void *smdThread() {
		bool rc = true;
		while(rc){
			rc = run_smd_loop();
		}
	
		Posix.exit(Posix.EXIT_FAILURE);
		return null;
	}

	public bool run_smd_loop() {
		int fatal_exit_code = 133;
		int[] p = new int[2]; 
		if (Posix.pipe(p) != 0) {
			stderr.printf("pipe() failed\n");
			return false;
		}
		Posix.pid_t pid;
		string cmd = smd_loop_cmd;
		if ( (pid = Posix.fork()) == 0 ){
			// son
			Posix.dup2(p[1],1);
			Posix.execl(cmd,cmd,"-v");
			stderr.printf("Unable to execute "+cmd+"\n");
			Posix.exit(fatal_exit_code);
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
					int pi = Posix.waitpid(pid,out rc,1); // WNOHANG
					if (pi == pid) {
						if ( (rc & 0x7f) == 0 && // WIFEXITED
							((rc & 0xff00)>>8) == fatal_exit_code){//WEXITSTATUS
						stderr.printf(cmd+" cannot be executed, aborting\n");
						Posix.exit(Posix.EXIT_FAILURE);
						} else {
							break;
						}
					}
				}
				if (n > 0) {
					ssize_t nread = Posix.read(p[0], buff, size);
					Posix.write(1,buff,nread);
				} else {
					break;
				}
			}
		} else {
			stderr.printf("fork() failed\n");
			return false;
		}
		return true;
	}

	// process an event in the events queue by notifying the user
	// with its message
	bool eat_event() {
		events_lock.lock();

		if ( events.length() > 0 && gconf.get_bool(key_newmail) ){

			Event e = events.nth(0).data;
			events.remove(e);
			var not = new Notify.Notification(
				"Syncmaildir",e.message,"gtk-about",null);
			not.attach_to_status_icon(si);
			try { not.show(); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		}

		events_lock.unlock();

		return true; // re-schedule me please
	}
	
	// starts the thread and the timeout handler
	public void run() { 
		// the thread fills the event queue
		try { thread = GLib.Thread.create(smdThread,true); }
		catch (GLib.ThreadError e) { 
			stderr.printf("Unable to start a thread\n"); 
			Posix.exit(Posix.EXIT_FAILURE);
		}

		// the timout function that will eventually notify the user
		GLib.Timeout.add(1000, eat_event);
		Gtk.main(); 
		thread.join();
	}
}

// =================== main =====================================

static int main(string[] args){
	// XXX should be read by a conf file (or included)
	string PREFIX = "@PREFIX@";

	// handle prefix
	if (PREFIX[0] == '@') {
		smdApplet.smd_loop_cmd = GLib.Environment.get_variable("HOME") + 
			"/Projects/syncmaildir/smd-pull";
			//"/Projects/syncmaildir/smd-loop";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-loop is: %s\n", smdApplet.smd_loop_cmd);
		smdApplet.smd_applet_ui = GLib.Environment.get_variable("HOME") + 
			"/Projects/syncmaildir/smd-applet.ui";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-applet.ui is: %s\n", smdApplet.smd_applet_ui);
	} else {
		smdApplet.smd_loop_cmd = PREFIX + "/bin/smd-loop";
		smdApplet.smd_applet_ui = PREFIX + "/share/smd-applet/smd-applet.ui";
	}

	// we init gtk+ and notify
	Gtk.init (ref args);
	Notify.init("smd-applet");

	// go!
	var smd_applet = new smdApplet();
	smd_applet.run();
	
	return Posix.EXIT_SUCCESS;
}

// vim:set ts=4:
