// Released under the terms of GPLv3 or at your option any later version.
// No warranties.
// Copyright 2009 Enrico Tassi <gares@fettunta.org>

errordomain Exit { ABORT }

bool verbose = false;

void debug(string message) {
	if (verbose) stderr.printf("DEBUG: %s\n",message);
}

// a simple class to pass data from the child process to the
// notofier
class Event {
	public string message;
	public bool enter_error_mode;

	public static Event error(string account, string host) {
		var e = new Event();
		e.message = "An error occurred, click on the icon for more details";
		e.enter_error_mode = true;
		return e;
	}

	public static Event stats(
		string account,string host,int new_mails,int del_mails) 
	{
		string preamble = "Synchronize with %s:\n".printf(account);
		var e = new Event();
		e.enter_error_mode = false;
		if (new_mails > 0 && del_mails > 0) {
			e.message = "%s%d new messages\n%d deleted messages".
				printf(preamble,new_mails,del_mails);
		} else if (new_mails > 0) {
			e.message = "%s%d new messages".printf(preamble,new_mails);
		} else {
			e.message = "%s%d deleted messages".printf(preamble,del_mails);
		}
		return e;
	}
}

static const string SMD_LOOP = "/bin/smd-loop";
static const string SMD_PUSH = "/bin/smd-push";
static const string SMD_APPLET_UI = "/share/syncmaildir-applet/smd-applet.ui";
static string SMD_LOOP_CFG;
static string SMD_PP_DEF_CFG;

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
	public static string smd_push_cmd = null;

	// =================== the data =====================================

	// The builder
	Gtk.Builder builder = null;

	// main widgets
	Gtk.Menu menu = null;
	Gtk.StatusIcon si = null;
	Gtk.Window win = null;
	Gtk.Window err_win = null;
	Gtk.Dialog about_win = null;

	// the gconf client handler
	GConf.Client gconf = null;

	// the thread to manage the child smd-loop instance
	weak GLib.Thread thread = null;
	bool thread_die = false;
	GLib.Pid pid = 0; // smd-loop pid
	
	// communication structure between the child process (managed by a thread
	// and the notifier timeout handler).
	GLib.Mutex events_lock = null;
	List<Event> events = null; 

	// if the program is stuck
	bool error_mode;
	bool config_wait_mode;
	GLib.HashTable<Gtk.Widget,string> command_hash = null;

	// ======================= constructor ================================

	// initialize data structures and build gtk+ widgets
	smdApplet() throws Exit {
		// load the ui file
		builder = new Gtk.Builder ();
		try { builder.add_from_file (smd_applet_ui); } 
		catch (GLib.Error e) { 
			stderr.printf("%s\n",e.message); 
			throw new Exit.ABORT("Unable to load the ui file");
		}
	
		// events queue and mutex
		events = new List<Event>();
		events_lock = new GLib.Mutex();

		// connect to gconf
		gconf = GConf.Client.get_default();

		// load widgets and attach callbacks
		win = builder.get_object("wPrefs") as Gtk.Window;
		err_win = builder.get_object("wError") as Gtk.Window;
		about_win = builder.get_object("wAbout") as Gtk.Dialog;

		var close = builder.get_object("bClosePrefs") as Gtk.Button;
		close.clicked += close_prefs_action;

		var bicon = builder.get_object("cbIcon") as Gtk.CheckButton;
		bicon.set_active( gconf.get_bool(key_icon));
		bicon.toggled += (b) => {
			try { gconf.set_bool(key_icon,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
			si.set_visible(!gconf.get_bool(key_icon));
		};
		var bnotify = builder.get_object("cbNotify") as Gtk.CheckButton;
		bnotify.set_active( gconf.get_bool(key_newmail));
		bnotify.toggled += (b) => {
			try { gconf.set_bool(key_newmail,b.active); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		};
		var bc = builder.get_object("bClose") as Gtk.Button;
		bc.clicked += close_err_action;

		var bel = builder.get_object("bEditLoopCfg") as Gtk.Button;
		bel.clicked += (b) => {
			// if not existent, create the template first
			try {
				if (!is_smd_loop_configured()){
			 		GLib.Process.spawn_command_line_sync(
						"%s -t".printf(smd_loop_cmd));
			 	}
				string cmd = "gnome-open %s".printf(SMD_LOOP_CFG);
				GLib.Process.spawn_command_line_async(cmd);
				is_smd_loop_configured();
			} catch (GLib.SpawnError e) {
				stderr.printf("%s\n",e.message);
			}
		};
		var bepp = builder.get_object("bEditPushPullCfg") as Gtk.Button;
		bepp.clicked += (b) => {
			// if not existent, create the template first
			try {
				if (!is_smd_pushpull_configured()){
			 		GLib.Process.spawn_command_line_sync(
						"%s -t".printf(smd_push_cmd));
			 	}
				string cmd = "gnome-open %s".printf(SMD_PP_DEF_CFG);
				GLib.Process.spawn_command_line_async(cmd);
				is_smd_pushpull_configured();
			} catch (GLib.SpawnError e) {
				stderr.printf("%s\n",e.message);
			}
		};

		// menu popped up when the user clicks on the notification area
        menu = builder.get_object ("mMain") as Gtk.Menu;
		var quit = builder.get_object ("miQuit") as Gtk.MenuItem;
		quit.activate += (b) => { 
			thread_die = true;
			if ((int)pid != 0) {
				Posix.kill((Posix.pid_t)(-(int)pid),Posix.SIGTERM);
			}
			Gtk.main_quit(); 
		};
		var about = builder.get_object ("miAbout") as Gtk.MenuItem;
		about_win.response += (id) => { about_win.hide(); };
		about.activate += (b) => { about_win.run(); };
		var prefs = builder.get_object ("miPrefs") as Gtk.MenuItem;
		prefs.activate += (b) => {  win.show(); };

		si = new Gtk.StatusIcon.from_icon_name("mail-send-receive");
		si.activate += (s) => { 
			if ( error_mode ) 
				err_win.reshow_with_initial_size();
			else if( config_wait_mode )
				win.show();
			else
				menu.popup(null,null,si.position_menu,0,
					Gtk.get_current_event_time());
		};

		// error mode data
		command_hash = new GLib.HashTable<Gtk.Widget,string>(
			GLib.direct_hash,GLib.str_equal);
	}

	// ===================== smd-loop handling ============================

	// This thread fills the event queue, parsing the
	// stdout of a child process 
	private void *smdThread() {
		bool rc = true;
		while(rc && !thread_die){
			debug("(re)starting smd-loop");
			rc = run_smd_loop();
		}
	
		return null;
	}

	private bool eval_smd_loop_error_message(
		string args, string account, string host) throws GLib.RegexError{
		var context = new GLib.Regex("context\\(([^\\)]+)\\)");
		var cause = new GLib.Regex("probable-cause\\(([^\\)]+)\\)");
		var human = new GLib.Regex("human-intervention\\(([^\\)]+)\\)");
		var actions=new GLib.Regex("suggested-actions\\((.*)\\) *$");

		GLib.MatchInfo i_ctx=null, i_cause=null, i_human=null, i_act=null;

		if (! context.match(args,0,out i_ctx)){
			stderr.printf("smd-loop error with no context: %s\n",args);
			return true;
		}
		if (! cause.match(args,0,out i_cause)){
			stderr.printf("smd-loop error with no cause: %s\n",args);
			return true;
		}
		if (! human.match(args,0,out i_human)){
			stderr.printf("smd-loop error with no human: %s\n",args);
			return true;
		}
		var has_actions = actions.match(args,0,out i_act);

		// widget setup
		var l_ctx = builder.get_object("lContext") as Gtk.Label;
		l_ctx.set_text(i_ctx.fetch(1));
		var l_cause = builder.get_object("lCause") as Gtk.Label;
		l_cause.set_text(i_cause.fetch(1));
		if ( i_human.fetch(1) != "necessary" ){
			stderr.printf("smd-loop giving an avoidable error: %s\n", args);
			return true;
		}
		bool display_permissions = false;
		bool display_mail = false;
		bool display_commands = false;
		
		if (has_actions) {
			command_hash.remove_all();
			var vb = builder.get_object("vbRun") as Gtk.VBox;
			foreach(Gtk.Widget w in vb.get_children()){ vb.remove(w); } 

			string acts = i_act.fetch(1);
			
			var r_perm = new GLib.Regex("display-permissions\\(([^\\)]+)\\)");
			var r_mail = new GLib.Regex("display-mail\\(([^\\)]+)\\)");
			var r_cmd = new GLib.Regex("run\\(([^\\)]+)\\)");

			int from = 0;
			for (;acts != null && acts.len() > 0;){
				MatchInfo i_cmd = null;
				if ( r_perm.match(acts,0,out i_cmd) ){
					display_permissions = true;
					i_cmd.fetch_pos(0,null,out from);
					string file = i_cmd.fetch(1);
					string output = null;
					string err = null;
					try {
						GLib.Process.spawn_command_line_sync(
							"ls -ld " + file, out output, out err);
						var l = builder.get_object("lPermissions") as Gtk.Label;
						l.set_text(output + err);
					} catch (GLib.SpawnError e) {
						stderr.printf("Spawning ls: %s\n",e.message);
					}
				} else if ( r_mail.match(acts,0,out i_cmd) ){
					display_mail = true;
					i_cmd.fetch_pos(0,null,out from);
					string file = i_cmd.fetch(1);
					string output = null;
					string err = null;
					try {
						var fn = builder.get_object("eMailName") as Gtk.Entry;
						fn.set_text(file);
						GLib.Process.spawn_command_line_sync(
							"cat " + file, out output, out err);
						var l = builder.get_object("tvMail") as Gtk.TextView;
						Gtk.TextBuffer b = l.get_buffer();
						b.set_text(output + err,-1);
						Gtk.TextIter it,subj;
						b.get_start_iter(out it);
						if (it.forward_search("Subject:",
							Gtk.TextSearchFlags.TEXT_ONLY, out subj,null,null)){
							var insert = b.get_insert();
							b.select_range(subj,subj);
							l.scroll_to_mark(insert,0.0,true,0.0,0.0);
						}
					} catch (GLib.SpawnError e) {
						stderr.printf("Spawning ls: %s\n",e.message);
					}
				} else if ( r_cmd.match(acts,0,out i_cmd) ){
					display_commands = true;
					string command = i_cmd.fetch(1);
					i_cmd.fetch_pos(0,null,out from);
					var hb = new Gtk.HBox(false,10);
					var lbl = new Gtk.Label(command);
					lbl.set_alignment(0.0f,0.5f);
					var but = new Gtk.Button.from_stock("gtk-execute");
					command_hash.insert(but,command);
					but.clicked += (b) => {
						int cmd_status;
						string output;
						string error;
						debug("executing: %s\n".printf(command_hash.lookup(b)));
						//XXX take host into account
						try{
						GLib.Process.spawn_command_line_sync(
							command_hash.lookup(b),
							out output,out error,out cmd_status);
						if (GLib.Process.if_exited(cmd_status) &&
							0==GLib.Process.exit_status(cmd_status)){
							// OK!
							b.set_sensitive(false);
						} else {
							var w = new Gtk.MessageDialog(err_win,
								Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR,
								Gtk.ButtonsType.CLOSE, 
								"An error occurred:\n%s\n%s",output,error);
							w.run();
							w.destroy();
						}
						} catch (GLib.SpawnError e) {
							stderr.printf("Spawning: %s\n",e.message);
						}
					};
					hb.pack_end(lbl,true,true,0);
					hb.pack_end(but,false,false,0);
					vb.pack_end(hb,true,true,0);
					hb.show_all();
				} else {
					stderr.printf("Unrecognized action: %s\n",acts);
					break;
				}
				acts = acts.substring(from);
			}
		}

		var x = builder.get_object("fDisplayPermissions") as Gtk.Widget;
		x.visible=display_permissions;
		x = builder.get_object("fDisplayMail") as Gtk.Widget; 
		x.visible=display_mail;
		x = builder.get_object("fRun") as Gtk.Widget; 
		x.visible=display_commands;
		
		events_lock.lock();
		events.append(Event.error(account,host));
		events_lock.unlock();
		return false;
	}

	// return true if successful, false to stop due to an error
	private bool eval_smd_loop_message(string s){
		try {
			GLib.MatchInfo info = null;
			var r_tags = new GLib.Regex(
				"^([^:]+): smd-(client|server)@([^:]+): TAGS:(.*)$");
			var r_skip = new GLib.Regex(
				"^([^:]+): smd-(client|server)@([^:]+): ERROR");

			if (r_skip.match(s,0,null)) { return true; }
			if (!r_tags.match(s,0,out info)) {
				debug("unhandled smd-loop message: %s".printf(s));
				return true;
			}
			
			var account = info.fetch(1);
			var host = info.fetch(3);
			var tags = info.fetch(4);
			
			GLib.MatchInfo i_args = null;
			var r_stats = new GLib.Regex(" stats::(.*)$");
			var r_error = new GLib.Regex(" error::(.*)$");

			if (r_stats.match(tags,0,out i_args)) {
				var r_neW = new GLib.Regex("new-mails\\(([0-9]+)\\)");
				var r_del = new GLib.Regex("del-mails\\(([0-9]+)\\)");
				GLib.MatchInfo i_new = null, i_del = null;
				var args = i_args.fetch(1);

				// check if matches
				var has_new = r_neW.match(args,0,out i_new); 
				var has_del = r_del.match(args,0,out i_del);

				int new_mails = 0;
				if (has_new) { new_mails = i_new.fetch(1).to_int();	}
				int del_mails = 0;
				if (has_del) { del_mails = i_del.fetch(1).to_int();	}

				if (host == "localhost" && (new_mails > 0 || del_mails > 0)) {
					events_lock.lock();
					events.append(
						Event.stats(account,host,new_mails, del_mails));
					events_lock.unlock();
				} else {
					// we skip non-error messages from the remote host
				}

				return true;
			} else if (r_error.match(tags,0,out i_args)) { 
				var args = i_args.fetch(1);
				return eval_smd_loop_error_message(args,account,host);
			} else {
				stderr.printf("unhandled smd-loop message: %s\n",s);
				return true;
			}
		} catch (GLib.RegexError e) { stderr.printf("%s\n",e.message); }
		return true;
	}

	// runs smd loop once, returns true if it stopped
	// with a recoverable error and thus should be restarted
	private bool run_smd_loop() throws Exit {
		string[] cmd = { smd_loop_cmd, "-v" };
		int child_in;
		int child_out;
		int child_err;
		char[] buff = new char[1024];
		GLib.SpawnFlags flags = 0;
		bool rc;
		debug("spawning %s\n".printf(smd_loop_cmd));
		try {
			rc = GLib.Process.spawn_async_with_pipes(
				null,cmd,null,flags,() => {  
					// create a new session
					Posix.setpgid(0,0);
				},
				out pid, out child_in, out child_out, out child_err);
		} catch (GLib.Error e) {
			stderr.printf("Unable to execute "+
				smd_loop_cmd+": "+e.message+"\n");
			throw new Exit.ABORT("Unable to run smd-loop");
		}

		if (rc) {
			var input = GLib.FileStream.fdopen(child_out,"r");
			string s = null;
			bool goon = true;
			while ( goon && (s = input.gets(buff)) != null && !thread_die) {
				debug("smd-loop outputs: %s".printf(s));
				goon = eval_smd_loop_message(s);
				debug("eval_smd_loop_message returned %d".printf((int)goon));
			}
			if ( s != null ) {
				// smd-loop prints the error tag as its last action
				if ( (s = input.gets(buff)) != null ){
					stderr.printf("smd-loop gave error tag but not died\n");
					stderr.printf("smd-loop has pid %d and prints %s\n",
						(int)pid, s);
				}
			}
			GLib.Process.close_pid(pid);
			Posix.kill((Posix.pid_t) (-(int)pid),Posix.SIGTERM);
			return goon; // maybe true, if s == null
		} else {
			stderr.printf("Unable to execute "+smd_loop_cmd+"\n");
			throw new Exit.ABORT("Unable to run smd-loop");
		}
	}

	// process an event in the events queue by notifying the user
	// with its message
	bool eat_event() {
		Event e = null;

		// in error mode no events are processed
		if ( error_mode ) return true;

		// fetch the event
		events_lock.lock();
		if ( events.length() > 0) {
			e = events.nth(0).data;
			events.remove(e);
		}
		events_lock.unlock();

		// regular notification
		if ( e != null && gconf.get_bool(key_newmail) ){
			var not = new Notify.Notification(
				"Syncmaildir",e.message,"gtk-about",null);
			not.attach_to_status_icon(si);

			try { not.show(); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		}

		// error notification
		if ( e != null && e.enter_error_mode ) {
			si.set_from_icon_name("error");
			si.set_blinking(true);
			error_mode = true;
		}

		return true; // re-schedule me please
	}

	// ===================== named signal handlers =======================

	// these are just wrappers for close_err
	private void close_err_action(Gtk.Button b){ close_err(); }
	private bool close_err_event(Gdk.Event e){
		close_err();
		return true;
	}

	private void close_err() {
		err_win.hide();	
		error_mode = false;
		si.set_from_icon_name("mail-send-receive");
		si.set_blinking(false);
		debug("joining smdThread");
		thread.join();
		debug("starting smdThread");
		try { thread = GLib.Thread.create(smdThread,true); }
		catch (GLib.ThreadError e) { 
			stderr.printf("Unable to re-start a thread\n"); 
			Gtk.main_quit();
		}
	}
	
	// these are just wrappers for close_prefs
	private void close_prefs_action(Gtk.Button b){ close_prefs(); }
	private bool close_prefs_event(Gdk.Event e){
		close_prefs();
		return true;
	}

	// close the prefs button, eventually start the theread if exiting
	// config_wait_mode
	private void close_prefs(){
		win.hide(); 
		if (is_smd_stack_configured() && config_wait_mode) {
			config_wait_mode = false;
			debug("starting smdThread since smd stack is configured");
			try { thread = GLib.Thread.create(smdThread,true); }
			catch (GLib.ThreadError e) { 
				stderr.printf("Unable to re-start a thread\n"); 
				Gtk.main_quit();
			}
			si.set_visible(!gconf.get_bool(key_icon));
			si.set_from_icon_name("mail-send-receive");
		}
	}

	// these are names for gtk_main_quit(), they are needed
	// in order to remove signal handlers
	private void my_gtk_main_quit_button(Gtk.Button b) { Gtk.main_quit(); }
	private bool my_gtk_main_quit_event(Gdk.Event b) {
		Gtk.main_quit();
		return false;
	}

	// ======================== config check ===========================

    private bool is_smd_loop_configured() {
		bool rc = GLib.FileUtils.test(SMD_LOOP_CFG,GLib.FileTest.EXISTS);
		Gtk.Label l = builder.get_object("lErrLoop") as Gtk.Label;
		if (!rc) l.show();
		else l.hide();
		return rc;
	}

    private bool is_smd_pushpull_configured() {
		bool rc = GLib.FileUtils.test(SMD_PP_DEF_CFG,GLib.FileTest.EXISTS);
		Gtk.Label l = builder.get_object("lErrPushPull") as Gtk.Label;
		if (!rc) l.show();
		else l.hide();
		return rc;
	}

	private bool is_smd_stack_configured() {
		var a = is_smd_loop_configured();
		var b = is_smd_pushpull_configured();
		return a && b;
	}

	// ====================== public methods ==============================

	// starts the thread and the timeout handler
	public void run() throws Exit { 

		// the timout function that will eventually notify the user
		GLib.Timeout.add(1000, eat_event);
		
		// before running, we need the whole smd stack
		// to be configured
    	if (is_smd_stack_configured()) {
			// the thread fills the event queue
			try { thread = GLib.Thread.create(smdThread,true); }
			catch (GLib.ThreadError e) { 
				stderr.printf("Unable to start a thread\n"); 
				throw new Exit.ABORT("Unable to spawn a thread");
			}
		} else {
			config_wait_mode = true;
		}

		// windows will last for the whole execution,
		// so the (x) button should just hide them
		win.delete_event += close_prefs_event;
		err_win.delete_event += close_err_event;

		// we show the icon if we have to.
		// this is performed here and not in the constructor
		// since if we passed --configure the icon has not
		// to be shown
		if ( config_wait_mode ) {
			si.set_visible(true);
			Posix.sleep(5);
			si.set_from_icon_name("error"); 
			var not = new Notify.Notification(
				"Syncmaildir","Syncmaildir is not configured properly, "+
				"click on the icon to configure it.","gtk-warning",null);
			not.attach_to_status_icon(si);
			try { not.show(); }
			catch (GLib.Error e) { stderr.printf("%s\n",e.message); }
		} else {
			si.set_visible(!gconf.get_bool(key_icon));
		}

		Gtk.main(); 
		if (thread != null) thread.join();
	}

	// just displays the config win
	public void configure() {
		var close = builder.get_object("bClosePrefs") as Gtk.Button;
		close.clicked += my_gtk_main_quit_button;
		win.delete_event += my_gtk_main_quit_event;
		win.show();	
		Gtk.main(); 
		close.clicked -= my_gtk_main_quit_button;
		win.delete_event -= my_gtk_main_quit_event;
	}

} // class end

// =================== main =====================================

static int main(string[] args){
	string PREFIX = SMDConf.PREFIX;

	// handle prefix
	if (! GLib.FileUtils.test(PREFIX + SMD_APPLET_UI,GLib.FileTest.EXISTS)) {
		stderr.printf("error: file not found: %s + %s\n", 
			PREFIX, SMD_APPLET_UI);
		smdApplet.smd_loop_cmd = "./smd-loop";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-loop is: %s\n", smdApplet.smd_loop_cmd);
		smdApplet.smd_applet_ui = "./smd-applet.ui";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-applet.ui is: %s\n", smdApplet.smd_applet_ui);
		smdApplet.smd_push_cmd = "./smd-push";
		stderr.printf("smd-applet not installed, " +
			"assuming smd-push is: %s\n", smdApplet.smd_push_cmd);
	} else {
		smdApplet.smd_loop_cmd = PREFIX + SMD_LOOP;
		smdApplet.smd_push_cmd = PREFIX + SMD_PUSH;
		smdApplet.smd_applet_ui = PREFIX + SMD_APPLET_UI; 
	}

	SMD_LOOP_CFG = GLib.Environment.get_home_dir()+"/.smd/loop";
	SMD_PP_DEF_CFG = GLib.Environment.get_home_dir()+"/.smd/config.default";

	// we init gtk+ and notify
	Gtk.init (ref args);
	Notify.init("smd-applet");

	bool config_only=false;
	GLib.OptionEntry[] oe = {
      GLib.OptionEntry () { 
		long_name = "configure", short_name = 'c', 
		flags = GLib.OptionFlags.NO_ARG, arg = GLib.OptionArg.NONE,
		arg_data = &config_only,
		description = "show config window, don't really run the applet",
		arg_description = null },
      GLib.OptionEntry () { 
		long_name = "verbose", short_name = 'v',
		flags = GLib.OptionFlags.NO_ARG, arg = GLib.OptionArg.NONE,
		arg_data = &verbose,
		description = "verbose output, for debugging only",
		arg_description = null },
      GLib.OptionEntry () { 
		long_name = "smd-loop", short_name = 'l',
		flags = 0, arg = GLib.OptionArg.STRING,
		arg_data = &smdApplet.smd_loop_cmd,
		description = "override smd-loop command name, debugging only",
		arg_description = "program" },
      GLib.OptionEntry () { long_name = null }
    };

	var oc = new GLib.OptionContext(" - syncmaildir applet");
	oc.add_main_entries(oe,null);
	try { oc.parse(ref args); }
	catch (GLib.OptionError e) { stderr.printf("%s\n",e.message); return 1; } 

	// go!
	try { 
		var smd_applet = new smdApplet();
    	if ( config_only ) {
			smd_applet.configure();
		} else {
			smd_applet.run();
		}
	} catch (Exit e) { 
		stderr.printf("abort: %s\n",e.message); 
	}
	
	return 0;
}

// vim:set ts=4:foldmethod=marker:
