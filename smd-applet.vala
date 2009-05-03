using Gtk;

static int main(string[] args){
	Gtk.init (ref args);
	var si = new StatusIcon.from_stock(Gtk.STOCK_NETWORK);
	si.set_visible(true);
	si.activate += (s) => { Gtk.main_quit(); };

	Gtk.main();
	
	return 0;
}
