// Released under the terms of GPLv3 or at your option any later version.
// No warranties.
// Copyright 2009 Enrico Tassi <gares@fettunta.org>

// TODO : use glib checksum functions instead of gcrypt

// a simple class to pass data from the child process to the
// notofier
class Event {
	public string message;

	Event(string s) {
		message = s;
	}
}

static const string SMD_LOOP = "/bin/smd-loop";
static const string SMD_APPLET_UI = "/share/smd-applet/smd-applet.ui";

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
	
		return null;
	}

	public bool eval_smd_loop_message(string s){
		try {
			GLib.MatchInfo info = null;
			var stats = new GLib.Regex(
				"^([^:]+): smd-(client|server)@([^:]+): TAGS: stats::(.*)$");
			var error = new GLib.Regex(
				"^([^:]+): smd-(client|server)@([^:]+): TAGS: error::(.*)$");
			var skip = new GLib.Regex("^ERROR:");
			if (stats.match(s,0,out info)) {
				var neW = new GLib.Regex("new-mails\\(([0-9]+)\\)");
				var del = new GLib.Regex("del-mails\\(([0-9]+)\\)");
				GLib.MatchInfo i_new = null, i_del = null;

				// check if matches
				neW.match(info.fetch(4),0,out i_new);
				del.match(info.fetch(4),0,out i_del);

				int new_mails = i_new.fetch(1).to_int();	
				int del_mails = i_del.fetch(1).to_int();	

				string message = null;
				if (del_mails > 0) {
					message = " %d new mails\n %d mails were deleted".
						printf(new_mails,del_mails);
				} else {
					message = " %d new mails".
						printf(new_mails);
				}
				events_lock.lock();
				events.append(new Event(
					"Mail synchronization with <i>%s</i>:\n%s".
					printf(info.fetch(1),message)));
				events_lock.unlock();
				return false;
			} else if (error.match(s,0,out info)) {
				var context = new GLib.Regex("context\\(([^\\)]+)\\)");
				var cause = new GLib.Regex("probable-cause\\(([^\\)]+)\\)");
				var human = new GLib.Regex("human-intervention\\(([^\\)]+)\\)");
				//var actions = new GLib.Regex("suggested-action\\(([^\\)]+)\\)");
				GLib.MatchInfo i_ctx = null, i_cause = null, i_human = null;
				//GLib.MatchInfo i_act = null;

				if (! context.match(info.fetch(3),0,out i_ctx)){
					stderr.printf("smd-loop error with no context: %s\n",info.fetch(2));
					return true;
				}
				if (! cause.match(info.fetch(3),0,out i_cause)){
					stderr.printf("smd-loop error with no cause: %s\n",s);
					return true;
				}
				if (! human.match(info.fetch(3),0,out i_human)){
					stderr.printf("smd-loop error with no human: %s\n",s);
					return true;
				}
				stderr.printf("IMPLEMENT ME\n");
				return false;
			} else if (skip.match(s,0,out info)) {
				return false; // skip that message, not for us
			} else {
				stderr.printf("unhandled smd-loop message: %s\n",s);
				return true;
			}
		} catch (GLib.RegexError e) { stderr.printf("%s\n",e.message); }
		return true;
	}

	public bool run_smd_loop() {
		//string[] cmd = { smd_loop_cmd, "-v" };
		//string[] cmd = {"/bin/echo","default: smd-client: TAGS: statistics::new-mails(1), del-mails(3)"};
		string[] cmd = {"/bin/echo","default: smd-client: TAGS: error::context(foo), probable-cause(dunno), human-intervention(required), sugged-action('foo')"};
		int child_in;
		int child_out;
		int child_err;
		char[] buff = new char[1024];
		GLib.Pid pid;
		GLib.SpawnFlags flags = 0;
		try {
			bool rc = GLib.Process.spawn_async_with_pipes(
				null,cmd,null,flags,null,
				out pid, out child_in, out child_out, out child_err);
			if (rc) {
				var input = GLib.FileStream.fdopen(child_out,"r");
				string s = null;
				bool stop = false;
				while ( !stop && (s = input.gets(buff)) != null ) {
					stop = eval_smd_loop_message(s);
				}
				return false;
			} else {
				stderr.printf("Unable to execute "+smd_loop_cmd+"\n");
				Posix.exit(Posix.EXIT_FAILURE);
			}
		} catch (GLib.Error e) {
			stderr.printf("Unable to execute "+
				smd_loop_cmd+": "+e.message+"\n");
			return false;
		}

		return true;
	}

	// process an event in the events queue by notifying the user
	// with its message
	bool eat_event() {
		Event e = null;

		events_lock.lock();
		if ( events.length() > 0) {
			e = events.nth(0).data;
			events.remove(e);
		}
		events_lock.unlock();

		if ( e != null && gconf.get_bool(key_newmail) ){
			var not = new Notify.Notification(
				"Syncmaildir",e.message,"gtk-about",null);
			not.attach_to_status_icon(si);

			try { not.show(); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		}

		return true; // re-schedule me please
	}
	
	// starts the thread and the timeout handler
	public void run() { 
		// the timout function that will eventually notify the user
		GLib.Timeout.add(1000, eat_event);
		
		// the thread fills the event queue
		try { thread = GLib.Thread.create(smdThread,true); }
		catch (GLib.ThreadError e) { 
			stderr.printf("Unable to start a thread\n"); 
			Posix.exit(Posix.EXIT_FAILURE);
		}

		Gtk.main(); 
		thread.join();
	}
}

// =================== main =====================================

static int main(string[] args){
	string PREFIX = SMDConf.PREFIX;

	// handle prefix
	if (! GLib.FileUtils.test(PREFIX + SMD_APPLET_UI,GLib.FileTest.EXISTS)) {
		smdApplet.smd_loop_cmd = GLib.Environment.get_variable("HOME") + 
			"/Projects/syncmaildir/smd-loop";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-loop is: %s\n", smdApplet.smd_loop_cmd);
		smdApplet.smd_applet_ui = GLib.Environment.get_variable("HOME") + 
			"/Projects/syncmaildir/smd-applet.ui";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-applet.ui is: %s\n", smdApplet.smd_applet_ui);
	} else {
		smdApplet.smd_loop_cmd = PREFIX + SMD_LOOP;
		smdApplet.smd_applet_ui = PREFIX + SMD_APPLET_UI; 
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
