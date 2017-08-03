module main;

import std.algorithm.mutation;
import std.algorithm;
import std.array;
import std.digest.sha;
import std.file;
import std.getopt;
import std.net.curl;
import std.path;
import std.range.primitives;
import std.range;
import std.stdio;
import std.string;
import std.traits;

import jsonizer;

enum WallpaperMode
{
	none,
	first,
	newest,
}

struct BingWallpaper
{
	mixin JsonizeMe;

@jsonize:
	uint id;
	string url;
	string query;
	string date;
	string category;
	string copyright;
	uint width;
	uint height;
	string thumbnail;
	string orgpage;
	string author;
	string authorlink;
	string licenselink;
	string title;
	string license;
	string thnwidth;
	string thnheight;
	string checksum;
}

const string jsonNew = "bing-desktop.json";
const string jsonOld = "bing-desktop.old";

string jsonUrl = "http://az542455.vo.msecnd.net/bing/en-us";
string outDir;

bool downloadExists;
bool noPause;
bool forceDownload;
bool allowOverwrite;
auto wallpaperMode = WallpaperMode.newest;

const string usage_str = `Lightweight multi-platform Bing Desktop client for downloading daily Bing wallpapers.

Usage:
	bingdesktop [options]

Options:`;

void pause()
{
	if (!noPause)
	{
		stdin.readln();
	}
}

int main(string[] args)
{
	try
	{
		auto result = getopt(args, "url|u",
				"The URL to the Bing Desktop metadata json.",
				&jsonUrl, "output|o", "Directory to save wallpapers.", &outDir, "no-pause|n",
				"Disable pause at the end of the program.",
				&noPause, "force-check|f",
				"Skip date validation and just download all wallpapers.", &forceDownload, "overwrite",
				"Allow wallpapers to be re-downloaded and overwritten.", &allowOverwrite, "mode|m",
				`Wallpaper selection mode. Valid options are "new" (first new wallpaper) and "newest".`
				~ `Default mode is "none"`, &wallpaperMode);

		if (result.helpWanted)
		{
			auto wangis = appender!string;
			defaultGetoptFormatter(wangis, null, result.options);
			stdout.write(usage_str);
			wangis.data.splitLines().each!(x => stdout.writefln("\t%s", x));
			return 0;
		}
	}
	catch (Exception ex)
	{
		stdout.writeln(ex.msg);
		pause();
		return -1;
	}

	if (outDir.empty)
	{
		outDir = getcwd();
	}

	if (exists(jsonNew))
	{
		rename(jsonNew, jsonOld);
	}

	download(jsonUrl, jsonNew);

	if (forceDownload || exists(jsonOld))
	{
		if (forceDownload || hashFile(jsonNew) != hashFile(jsonOld))
		{
			stdout.writeln("Downloading new images...");
			if (checkFiles())
			{
				return -1;
			}
		}
		else
		{
			stdout.writeln("Nothing new.");
			remove(jsonOld);
		}
	}
	else if (checkFiles())
	{

		return -1;
	}

	stdout.writeln();
	stdout.writeln("Operation complete.");
	pause();

	return 0;
}

auto hashFile(in string path)
{
	auto file = File(path, "rb");
	SHA256 digest;

	foreach (ubyte[] buffer; file.byChunk(4096))
	{
		digest.put(buffer);
	}

	auto result = digest.finish();
	return result;
}

// See isValidFilename in std.path
Range makeValidFilename(Range)(Range filename)
		if (((isRandomAccessRange!Range && hasLength!Range && hasSlicing!Range
			&& isSomeChar!(ElementEncodingType!Range)) || isNarrowString!Range) && !isConvertibleToString!Range)
{
	Appender!Range result;

	foreach (c; filename)
	{
		version (Windows)
		{
			switch (c)
			{
				case 0: .. case 31:
					case '<':
					case '>':
					case ':':
					case '"':
					case '/':
					case '\\':
					case '|':
					case '?':
					case '*':
					result.put('_');
					break;

				default:
					result.put(c);
					break;
			}
		}
		else version (Posix)
		{
			result.put((c == 0 || c == '/') ? '_' : c);
		}
	}

	return result.data;
}

int checkFiles()
{
	try
	{
		auto text = readText(jsonNew);
		auto file = fromJSONString!(BingWallpaper[])(text);
		string wallpaperFilename;

		foreach (BingWallpaper i; file)
		{
			if (i.date.empty)
			{
				stdout.writeln("Entry missing date!");
				continue;
			}

			// Format is YYYY-MM-DD query.jpg
			string name = format("%s-%s-%s %s.jpg", i.date[0 .. 4], i.date[4 .. 6], i.date[6 .. 8], i.query.strip());

			name = name.makeValidFilename();

			string oldpath = buildNormalizedPath(outDir, format("%d.jpg", i.id));
			string newpath = buildNormalizedPath(outDir, name);

			// If the file has been copied with its original ID name,
			// rename it to "date query.jpg"
			// e.g: 2014-09-17 A dredge boat near the Glénan Islands.jpg
			if (exists(oldpath))
			{
				stdout.writefln("Renaming %d.jpg to %s", i.id, name);
				rename(oldpath, newpath);
			}
			else // Otherwise, we just try to download.
			{
				if (allowOverwrite || !exists(newpath))
				{
					stdout.writeln("Downloading: " ~ i.copyright);
					download(i.url, newpath);

					// The json is sorted newest to oldest.
					// So if the wallpaper mode is set to newest, we set it upon download.
					// Otherwise, we'll keep setting the string to the "first" new downloaded,
					// then apply the wallpaper later.
					switch (wallpaperMode)
					{
						default:
							throw new Exception("WHAT EVEN");

						case WallpaperMode.newest:
							wallpaperFilename = newpath;
							wallpaperMode = WallpaperMode.none;
							break;
						case WallpaperMode.first:
							wallpaperFilename = newpath;
							break;
						case WallpaperMode.none:
							break;
					}
				}
				else
				{
					stdout.writeln("Skipping: " ~ name);
				}
			}
		}

		// Use the last set "first" new wallpaper string, then set it.
		if (!wallpaperFilename.empty)
		{
			setWallpaper(wallpaperFilename);
		}
	}
	catch (Exception e)
	{
		stdout.writeln(e.msg);
		pause();
		return 1;
	}

	return 0;
}

void setWallpaper(string filename)
{
	version (Windows)
	{
		import core.thread;
		import core.sys.windows.windows;

		wallpaperMode = WallpaperMode.none;

		bool result;
		for (size_t i; i < 4 && !result; i++)
		{
			result = SystemParametersInfoA(SPI_SETDESKWALLPAPER, 0,
					cast(void*)filename.toStringz(), SPIF_UPDATEINIFILE | SPIF_SENDCHANGE) > 0;

			if (!result)
			{
				stderr.writeln("Failed to set wallpaper.");
				Thread.sleep(250.msecs);
			}
		}
	}
	else version (linux)
	{
		import std.process : executeShell;

		executeShell(`gsettings set org.gnome.desktop.background picture-uri "file://`
				~ absolutePath(filename, "/") ~ `"`);
	}
	else
	{
		stdout.writeln("Sorry, wallapers can't be set your platform. They're still downloaded, though!");
	}
}
